# 마이그레이션 이후 필수 설정 가이드

## 개요
Terraform apply 완료 후 인스턴스에서 직접 수정해야 하는 설정들입니다.
팀원들이 빠르게 따라할 수 있도록 단계별로 정리했습니다.

---

## 0. 사전 준비 (Terraform apply 전에 실행)

### 0.0 DB1 데이터 확인 (선택사항)

**참고**: DB1에 테스트 데이터가 있어도 DMS가 정상적으로 복제합니다.

하지만 깨끗한 상태로 시작하고 싶다면:

```bash
# DB1 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 접속
mysql -u admin -ptest123!
```

```sql
-- 현재 데이터 확인
USE toydb;
SELECT COUNT(*) FROM users;

-- 데이터 삭제 (선택사항)
TRUNCATE TABLE users;

-- 확인
SELECT COUNT(*) FROM users;
-- 결과: 0

exit
```

**주의**: 
- 이 단계는 **선택사항**입니다
- DMS는 기존 데이터가 있어도 정상 작동합니다
- **RDS1, RDS2는 깡통(빈 상태)으로 생성됩니다** - DMS가 자동으로 toydb를 생성합니다

---

## 0.1 Lambda 재빌드 (PowerShell)

Lambda 함수를 빌드해야 합니다:

```powershell
# 프로젝트 루트로 이동
cd C:\Users\<YOUR_USERNAME>\OneDrive\바탕 화면\aws 11기 작업파일\toyproject_k8s

# Lambda 디렉토리로 이동
cd lambda

# 빌드 스크립트 실행 (자동으로 모든 Lambda 함수 빌드)
.\build.ps1

# 빌드 스크립트 오류가 뜬다면 powershell 오류입니다. (밑의 명령어 입력 후에 다시 빌드해보세요)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Terraform 디렉토리로 이동
cd ..\infrastructure\terraform

# Terraform apply
terraform apply
```

**주의**: 
- `<YOUR_USERNAME>` 부분을 본인의 Windows 사용자 이름으로 변경하세요
- `build.ps1` 스크립트가 자동으로 3개의 Lambda 함수를 빌드합니다:
  - `health_monitor.zip`
  - `failover_controller.zip`
  - `dms_chain_starter.zip`
- 빌드 완료 후 ZIP 파일이 lambda 폴더에 생성됩니다

---

## 0.2 Lambda 함수 수정 후 재배포 (개발 중)

Lambda 함수 코드를 수정한 후 재배포하는 방법입니다.

### 방법 1: build.ps1 사용 (권장)

```powershell
# Lambda 디렉토리로 이동
cd lambda

# 전체 재빌드
.\build.ps1

# AWS Lambda 업데이트
aws lambda update-function-code --function-name db-failover-health-monitor --zip-file fileb://health_monitor.zip
aws lambda update-function-code --function-name db-failover-failover-controller --zip-file fileb://failover_controller.zip
aws lambda update-function-code --function-name db-failover-dms-chain-starter --zip-file fileb://dms_chain_starter.zip
```

### 방법 2: 개별 함수만 재배포 (빠른 테스트용)

특정 Lambda 함수만 수정한 경우 해당 함수만 재빌드하고 배포할 수 있습니다:

#### Health Monitor 재배포
```powershell
cd lambda

# 압축
Compress-Archive -Path health_monitor.py,boto3,botocore,dateutil,jmespath,s3transfer,six.py,urllib3,pymysql -DestinationPath health_monitor.zip -Force

# 배포
aws lambda update-function-code --function-name db-failover-health-monitor --zip-file fileb://health_monitor.zip
```

#### Failover Controller 재배포
```powershell
cd lambda

# 압축
Compress-Archive -Path failover_controller.py,boto3,botocore,dateutil,jmespath,s3transfer,six.py,urllib3,pymysql -DestinationPath failover_controller.zip -Force

# 배포
aws lambda update-function-code --function-name db-failover-failover-controller --zip-file fileb://failover_controller.zip
```

#### DMS Chain Starter 재배포
```powershell
cd lambda

# 압축 (pymysql 제외)
Compress-Archive -Path dms_chain_starter.py,boto3,botocore,dateutil,jmespath,s3transfer,six.py,urllib3 -DestinationPath dms_chain_starter.zip -Force

# 배포
aws lambda update-function-code --function-name db-failover-dms-chain-starter --zip-file fileb://dms_chain_starter.zip
```

### Lambda 로그 확인

배포 후 Lambda가 정상 작동하는지 로그를 확인하세요:

```powershell
# Health Monitor 로그
aws logs tail /aws/lambda/db-failover-health-monitor --follow

# Failover Controller 로그
aws logs tail /aws/lambda/db-failover-failover-controller --follow

# DMS Chain Starter 로그
aws logs tail /aws/lambda/db-failover-dms-chain-starter --follow
```

**주의**:
- 개별 재배포 시 의존성 패키지(boto3, pymysql 등)가 이미 lambda 폴더에 있어야 합니다
- 처음 빌드할 때는 반드시 `build.ps1`을 사용하세요 (의존성 설치 포함)
- 코드만 수정한 경우 방법 2가 더 빠릅니다

---

## 1. Nginx 설정 수정 (Web 인스턴스)

### 1.1 접속
```bash
# Web1 또는 Web2 인스턴스 접속
aws ssm start-session --target <WEB_INSTANCE_ID>
```

### 1.2 Nginx 설정 파일 수정
```bash
# 설정 파일 열기
sudo vi /etc/nginx/sites-available/default
# 또는
sudo vi /etc/nginx/conf.d/default.conf
```

### 1.3 proxy_pass 부분만 수정
**기존 (로컬 VM 설정)**:
```nginx
location / {
    proxy_pass http://10.0.11.86:5000;  # WAS Private IP (하드코딩)
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

**수정 후 (WAS Private IP 사용)**:
```nginx
location / {
    proxy_pass http://<WAS_PRIVATE_IP>:5000;  # WAS Private IP로 변경
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

**WAS Private IP 확인**:
```bash
# Terraform output에서 WAS Instance ID 확인 후
aws ec2 describe-instances --instance-ids <WAS_INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

**주의**: 
- Web1은 WAS1 IP를, Web2는 WAS2 IP를 사용하는 것이 일반적입니다
- 또는 두 WAS IP를 모두 upstream으로 설정할 수도 있습니다

### 1.4 Nginx 재시작
```bash
# 설정 테스트
sudo nginx -t

# Nginx 재시작
sudo systemctl restart nginx

# 상태 확인
sudo systemctl status nginx
```

---

## 2. Flask 앱 설정 수정 (WAS 인스턴스)

### 2.1 접속
```bash
# WAS1 또는 WAS2 인스턴스 접속
aws ssm start-session --target <WAS_INSTANCE_ID>
```

### 2.2 app.py 파일 수정
```bash
# app.py 파일 열기
sudo vi /home/ubuntu/app/app.py
```

### 2.3 PooledDB 설정에서 host와 port만 수정
**기존 (로컬 VM 설정)**:
```python
pool = PooledDB(
    creator=pymysql,
    maxconnections=5,
    host="192.168.219.116",  # 로컬 MySQL IP
    port=3306,               # MySQL 포트
    user="was_user",
    password="test1234",
    database="toydb",
    cursorclass=cursors.DictCursor
)
```

**수정 후 (NLB + ProxySQL 사용)**:
```python
pool = PooledDB(
    creator=pymysql,
    maxconnections=5,
    host="<NLB_DNS_NAME>",   # NLB DNS로 변경
    port=6033,               # ProxySQL 포트로 변경
    user="was_user",
    password="test1234",
    database="toydb",
    cursorclass=cursors.DictCursor
)
```

**NLB DNS 이름 확인**:
```bash
cd infrastructure/terraform
terraform output nlb_dns_name
```

### 2.4 Flask 앱 재시작
```bash
# Flask 서비스 재시작
sudo systemctl restart flask-app

# 상태 확인
sudo systemctl status flask-app

# 로그 확인 (문제 발생 시)
sudo journalctl -u flask-app -f
```

---

## 3. ProxySQL 설정 수정 (ProxySQL 인스턴스)

### 3.1 접속
```bash
# ProxySQL1 또는 ProxySQL2 인스턴스 접속
aws ssm start-session --target <PROXYSQL_INSTANCE_ID>
```

### 3.2 ProxySQL 설정 파일 수정
```bash
# 설정 파일 열기
sudo vi /etc/proxysql.cnf
```

### 3.3 수정할 부분

#### 1) mysql_users 섹션에 was_user 추가

**기존**:
```
mysql_users:
(
    # was_user 없음
)
```

**수정 후**:
```
mysql_users:
(
    {
        username = "was_user"
        password = "test1234"
        default_hostgroup = 10
        max_connections = 1000
        active = 1
    }
)
```

#### 2) mysql_servers 섹션 수정 (중요!)

**기존 (로컬 VM 설정)**:
```
mysql_servers =
(
    { address="127.0.0.1", port=3306, hostgroup=10 },
    { address="/var/lib/mysql/mysql.sock", port=3306, hostgroup=10 }
)
```

**수정 후 (EC2 DB1 Private IP 사용)**:
```
mysql_servers =
(
    {
        address = "<EC2_DB1_PRIVATE_IP>"  # 예: 10.0.11.151
        port = 3306
        hostgroup = 10
        status = "ONLINE"
        weight = 1
    }
)
```

**EC2 DB1 Private IP 확인**:
```bash
# Terraform output에서 DB1 Instance ID 확인 후
aws ec2 describe-instances --instance-ids <DB1_INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

**중요**: 
- `127.0.0.1`과 Unix 소켓(`/var/lib/mysql/mysql.sock`) 항목은 **반드시 삭제**
- EC2 DB1의 Private IP만 남겨야 함


### 3.4 ProxySQL 캐시 삭제 및 재시작
```bash
# ProxySQL 중지
sudo systemctl stop proxysql

# 캐시 DB 삭제 (중요! 이 단계를 건너뛰면 설정이 반영 안됨)
sudo rm -f /var/lib/proxysql/proxysql.db

# ProxySQL 재시작
sudo systemctl start proxysql

**Proxysql 설정 반영(매우 중요!! : proxysql은 admin 접속 우회를 위해 꼭 설정을 추가로 해줘야 conf 내용이 반영됩니다.)**:
sudo apt update && sudo apt install python3-pymysql -y
vi apply_config.py (db-cloud-migration 폴더 밑에 있는 apply_config.py 내용을 복붙합니다.)
python3 apply_config.py

# 상태 확인
sudo systemctl status proxysql

# 로그 확인
sudo tail -f /var/lib/proxysql/proxysql.log
```

**주의**: `proxysql.db` 파일을 삭제하지 않으면 설정 파일 변경사항이 반영되지 않습니다!


### 3.4 RDS1,2에 WAS 사용자 입력(DMS는 데이터만 복제할 뿐, 사용자는 복제하지 않습니다.)

CREATE USER 'was_user'@'%' IDENTIFIED WITH mysql_native_password BY 'test1234';
GRANT SELECT, INSERT, UPDATE, DELETE ON toydb.* TO 'was_user'@'%';
FLUSH PRIVILEGES;

---


### 3.5 DB에 DMS 데이터 로드 활성화 적용(중요!)
SET GLOBAL local_infile = 1;"



## 4. DB1 사용자 확인 (문제 발생 시에만 실행)

**참고**: DB AMI에 admin, was_user, repl_user가 이미 포함되어 있습니다. 
**이 단계는 DMS 엔드포인트 테스트가 실패하거나 사용자가 없는 경우에만 실행하세요.**

### 4.1 사용자 확인
```bash
# DB1 인스턴스 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 접속
mysql -u admin -ptest123!
```

```sql
-- 사용자 목록 확인
SELECT user, host FROM mysql.user WHERE user IN ('admin', 'was_user', 'repl_user');

-- 예상 결과:
-- admin     | %
-- was_user  | %
-- repl_user | %

exit
```

### 4.2 사용자 생성 (없는 경우에만)

**admin 사용자가 없으면 DMS 연결 테스트가 실패합니다!**

```bash
# MySQL 접속 (root 권한)
mysql -u root -p
# 또는
mysql
```

```sql
-- admin 사용자 생성 (DMS용)
CREATE USER 'admin'@'%' IDENTIFIED BY 'test123!';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;

-- was_user 생성 (애플리케이션용)
CREATE USER 'was_user'@'%' IDENTIFIED WITH mysql_native_password BY 'test1234';
GRANT SELECT, INSERT, UPDATE, DELETE ON toydb.* TO 'was_user'@'%';

-- repl_user 생성 (Failover/Rollback용)
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl_password123';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';

-- 권한 적용
FLUSH PRIVILEGES;

-- 확인
SELECT user, host FROM mysql.user WHERE user IN ('admin', 'was_user', 'repl_user');

exit
```

**비밀번호:**
- admin: `test123!`
- was_user: `test1234`
- repl_user: `repl_password123`

---

## 5. DMS 자동 복제 확인

**중요**: DMS 태스크는 Terraform apply 시 자동으로 시작됩니다!

### 5.1 DMS 태스크 자동 시작 확인

Terraform apply 완료 후 DMS 태스크가 자동으로 시작됩니다:

**자동화 흐름:**
1. **DB1→RDS1 DMS**: Terraform이 자동 시작
2. **RDS1→RDS2 DMS**: DB1→RDS1 Full Load 완료 후 Lambda가 자동 시작
3. **SNS 알림**: RDS1→RDS2 Full Load 완료 시 "DB Synchronization Complete" 이메일 전송

### 5.2 DMS 태스크 상태 확인

```powershell
# DB1→RDS1 태스크 상태 확인
aws dms describe-replication-tasks `
  --filters "Name=replication-task-id,Values=db-failover-db1-to-rds1"

# RDS1→RDS2 태스크 상태 확인 (5-10분 후)
aws dms describe-replication-tasks `
  --filters "Name=replication-task-id,Values=db-failover-rds1-to-rds2"
```

**확인 사항:**
- `Status: running` - 정상 작동 중
- `Status: starting` - 시작 중
- `PercentComplete: 100` - 초기 복사 완료 (Full Load)

### 5.3 RDS1, RDS2 데이터 확인

```sql
-- RDS1에 접속
mysql -u admin -ptest123! -h <RDS1_ENDPOINT>

-- 데이터베이스 확인
SHOW DATABASES;
-- toydb가 생성되어 있어야 함

-- 테이블 확인
USE toydb;
SHOW TABLES;
-- users 테이블이 있어야 함

-- 데이터 확인
SELECT * FROM users;

exit
```

```sql
-- RDS2에 접속 (RDS1→RDS2 Full Load 완료 후)
mysql -u admin -ptest123! -h <RDS2_ENDPOINT>

-- 데이터베이스 확인
SHOW DATABASES;
-- toydb가 생성되어 있어야 함

-- 테이블 확인
USE toydb;
SHOW TABLES;
-- users 테이블이 있어야 함

-- 데이터 확인
SELECT * FROM users;

exit
```

### 5.4 문제 발생 시 (DMS 태스크가 시작 안 되는 경우)

**원인 1: DMS 엔드포인트 연결 테스트 실패**
- DB1에 admin 사용자가 없는 경우
- 해결: 섹션 4 참고하여 사용자 생성

**원인 2: RDS 인스턴스가 아직 준비 안 됨**
- RDS 생성 중이거나 초기화 중
- 해결: 5-10분 대기 후 재확인

**수동 시작 (최후의 수단):**
```powershell
# DB1→RDS1 DMS 수동 시작
aws dms start-replication-task `
  --replication-task-arn <DB1_TO_RDS1_TASK_ARN> `
  --start-replication-task-type start-replication

# RDS1→RDS2 DMS 수동 시작 (DB1→RDS1 완료 후)
aws dms start-replication-task `
  --replication-task-arn <RDS1_TO_RDS2_TASK_ARN> `
  --start-replication-task-type start-replication
```

**주의**:
- DMS가 자동으로 toydb 데이터베이스와 테이블을 생성합니다
- 복제 구조: DB1 (EC2) --DMS--> RDS1 --DMS--> RDS2
- 전체 동기화 완료까지 10-15분 소요

---

## 6. ProxySQL 설정 확인 (선택사항)

ProxySQL에는 mysql 클라이언트가 설치되지 않았으므로, **WAS 또는 DB1에서 원격으로 접속**합니다.

### 6.1 WAS 또는 DB1에서 ProxySQL Admin 접속
```bash
# WAS 또는 DB1 접속
aws ssm start-session --target <WAS_OR_DB1_INSTANCE_ID>

# ProxySQL Admin 원격 접속 (ProxySQL Private IP 사용)
mysql -u admin -padmin -h <PROXYSQL_PRIVATE_IP> -P 6032
```

### 6.2 설정 확인
```sql
-- 백엔드 서버 확인
SELECT * FROM mysql_servers;
-- 예상 결과: hostgroup_id=10, hostname=10.0.11.151, status=ONLINE

-- 사용자 확인
SELECT * FROM mysql_users;
-- 예상 결과: was_user와 admin 모두 존재

-- 연결 풀 상태 확인
SELECT * FROM stats_mysql_connection_pool;

-- 종료
exit
```

---

## 7. 전체 동작 확인

### 6.1 웹사이트 접속
```bash
# ALB DNS 이름 확인
cd infrastructure/terraform
terraform output alb_dns_name

# 브라우저에서 접속
http://<ALB_DNS_NAME>
```

### 6.2 확인 사항
- [ ] 웹사이트가 정상적으로 로드됨
- [ ] "Connected DB Host" 표시됨 (EC2 DB1 호스트명)
- [ ] 사용자 목록이 표시됨
- [ ] 새 사용자 추가 가능
- [ ] 504 Gateway Timeout 에러 없음
- [ ] Access Denied 에러 없음

### 6.3 문제 발생 시 로그 확인
```bash
# Nginx 로그 (Web 인스턴스)
sudo tail -f /var/log/nginx/error.log

# Flask 로그 (WAS 인스턴스)
sudo journalctl -u flask-app -f

# ProxySQL 로그 (ProxySQL 인스턴스)
sudo tail -f /var/lib/proxysql/proxysql.log

# MySQL 로그 (DB1 인스턴스)
sudo tail -f /var/log/mysql/error.log
```

---

## 8. 체크리스트

마이그레이션 완료 후 아래 항목들을 순서대로 확인하세요:

- [ ] **0단계**: Lambda 재빌드 (PowerShell)
- [ ] **0단계**: Terraform apply
- [ ] **1단계**: Web 인스턴스 Nginx 설정 수정 (`proxy_pass`에 WAS Private IP 사용)
- [ ] **2단계**: WAS 인스턴스 Flask app.py 수정 (`host`에 NLB DNS, `port`를 6033으로)
- [ ] **3단계**: ProxySQL 설정 파일 수정 (mysql_servers에 DB1 IP, mysql_users에 was_user 추가)
- [ ] **4단계**: ProxySQL 캐시 DB 삭제 (`/var/lib/proxysql/proxysql.db`) 및 재시작
- [ ] **5단계**: DMS 자동 복제 확인 (DB1→RDS1, RDS1→RDS2)
- [ ] **6단계**: 웹사이트 접속 테스트 (ALB DNS로 접속)
- [ ] **7단계**: CloudWatch Dashboard 확인
- [ ] **8단계**: CloudWatch Alarms 상태 확인 (모두 초록색)

---

## 9. 자주 발생하는 문제

### 문제 1: 504 Gateway Timeout
**원인**: Nginx가 WAS에 연결하지 못함
**해결**: Nginx 설정에서 WAS Private IP 사용 확인 (1단계)

### 문제 2: Access Denied for user 'was_user'
**원인**: ProxySQL 설정 또는 DB1 사용자 설정 문제
**해결**: 
1. ProxySQL 설정에 was_user 추가 (3단계)
2. DB1에서 was_user 재생성 (5단계)
3. ProxySQL 캐시 DB 삭제 (4단계)

### 문제 3: ProxySQL 설정 변경이 반영 안됨
**원인**: ProxySQL 캐시 DB가 설정 파일보다 우선순위가 높음
**해결**: `/var/lib/proxysql/proxysql.db` 파일 삭제 후 재시작

### 문제 4: Flask 앱이 DB에 연결 못함
**원인**: app.py에서 ProxySQL 주소가 잘못됨
**해결**: 
1. app.py에서 `host`를 NLB DNS로 변경
2. `port`를 6033으로 변경 (ProxySQL 애플리케이션 포트)
3. Flask 재시작: `sudo systemctl restart flask-app`

---

## 10. 중요 정보 요약

### 비밀번호
- DB admin: `test123!`
- DB was_user: `test1234`
- DB repl_user: `repl_password123` (복제용)
- ProxySQL admin: `admin`

### 포트
- Nginx: 80
- Flask: 5000
- ProxySQL: 6033 (애플리케이션), 6032 (Admin)
- MySQL: 3306

### 주요 IP/DNS
- NLB DNS: Terraform output에서 확인
- ALB DNS: Terraform output에서 확인
- DB1 Private IP: `10.0.11.151` (EC2 콘솔에서 확인)
- ProxySQL Private IP: EC2 콘솔에서 확인

---

## 11. EC2 DB1 MySQL 초기화 (선택사항)

**언제 사용하나요?**
- Terraform destroy 후 재생성했는데 기존 데이터가 남아있는 경우
- DB1의 데이터를 완전히 삭제하고 DMS로 새로 동기화하고 싶은 경우
- 테스트 중 데이터가 꼬여서 처음부터 다시 시작하고 싶은 경우

### 10.1 MySQL 완전 초기화

```bash
# DB1 인스턴스 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 중지
sudo systemctl stop mysql

# 데이터 디렉토리 완전 삭제
sudo rm -rf /var/lib/mysql/*

# MySQL 재초기화 (빈 데이터베이스로 시작)
sudo mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql

# MySQL 재시작
sudo systemctl start mysql

# 상태 확인
sudo systemctl status mysql
```

### 10.2 초기 보안 설정 (필수)

MySQL을 초기화하면 root 비밀번호가 없는 상태로 시작됩니다. 보안을 위해 반드시 설정해야 합니다:

```bash
# MySQL 보안 설정 실행
sudo mysql_secure_installation
```

**설정 과정**:

1. **Enter current password for root**: 그냥 Enter (비밀번호 없음)

2. **Switch to unix_socket authentication [Y/n]**: `n` 입력
   - unix_socket은 로컬 접속만 가능하므로 원격 접속을 위해 비활성화

3. **Change the root password? [Y/n]**: `Y` 입력
   - New password: `test123!`
   - Re-enter new password: `test123!`

4. **Remove anonymous users? [Y/n]**: `Y` 입력
   - 익명 사용자는 보안 위험이므로 삭제

5. **Disallow root login remotely? [Y/n]**: `n` 입력
   - 원격에서 root 접속이 필요하므로 허용 (프로덕션에서는 `Y` 권장)

6. **Remove test database and access to it? [Y/n]**: `Y` 입력
   - 테스트 데이터베이스는 불필요하므로 삭제

7. **Reload privilege tables now? [Y/n]**: `Y` 입력
   - 변경사항 즉시 적용

### 10.3 필수 사용자 및 데이터베이스 재생성

```bash
# MySQL 접속 (root 비밀번호 입력)
mysql -u root -ptest123!
```

```sql
-- admin 사용자 생성 (Terraform에서 사용)
CREATE USER 'admin'@'%' IDENTIFIED BY 'test123!';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;

-- was_user 생성 (애플리케이션에서 사용)
CREATE USER 'was_user'@'%' IDENTIFIED WITH mysql_native_password BY 'test1234';

-- repl_user 생성 (복제용)
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl_password123';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';

-- toydb 데이터베이스 생성
CREATE DATABASE toydb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- was_user에 toydb 권한 부여
GRANT SELECT, INSERT, UPDATE, DELETE ON toydb.* TO 'was_user'@'%';

-- 권한 적용
FLUSH PRIVILEGES;

-- 확인
SELECT user, host FROM mysql.user;
SHOW DATABASES;

-- 종료
exit
```

### 10.4 MySQL 설정 확인 (선택사항)

초기화 후 MySQL 기본 설정을 확인합니다:

```bash
# MySQL 설정 파일 확인
sudo vi /etc/mysql/mysql.conf.d/mysqld.cnf
```

기본 설정 예시:
```ini
[mysqld]
# 복제 설정
log_bin = /var/log/mysql/mysql-bin.log
server_id = 1
binlog_format = ROW

# 성능 최적화
max_connections = 200
innodb_buffer_pool_size = 1G
```

```bash
# MySQL 재시작 (설정 변경 시)
sudo systemctl restart mysql

# 상태 확인
mysql -u admin -ptest123! -e "SHOW VARIABLES LIKE 'log_bin';"
# 결과: log_bin | ON
```

### 10.5 DMS로 데이터 재동기화

DB1을 초기화했으므로 DMS를 통해 데이터를 다시 동기화해야 합니다:

```bash
# DMS 태스크 재시작 (로컬 PowerShell에서)
aws dms start-replication-task \
  --replication-task-arn <DMS_TASK_ARN> \
  --start-replication-task-type reload-target

# DMS 태스크 ARN 확인
cd infrastructure/terraform
terraform output dms_task_arn
```

**동기화 확인**:
```bash
# DB1에서 toydb 테이블 확인
mysql -u admin -ptest123! -e "USE toydb; SHOW TABLES;"

# 사용자 데이터 확인
mysql -u admin -ptest123! -e "USE toydb; SELECT * FROM users;"
```

### 10.6 초기화 후 체크리스트

- [ ] MySQL 초기화 완료 (`/var/lib/mysql/*` 삭제)
- [ ] `mysql_secure_installation` 실행 (root 비밀번호: `test123!`)
- [ ] admin, was_user, repl_user 재생성
- [ ] toydb 데이터베이스 생성
- [ ] MySQL 설정 확인 (`mysqld.cnf`)
- [ ] MySQL 재시작 및 바이너리 로그 확인
- [ ] DMS 태스크 재시작 (데이터 재동기화)
- [ ] 웹사이트에서 데이터 확인

**주의**: 
- 초기화하면 DB1의 모든 데이터가 삭제됩니다
- DMS 동기화가 완료될 때까지 웹사이트에서 데이터가 보이지 않습니다 (5-10분 소요)
- RDS1, RDS2는 영향받지 않습니다 (별도로 초기화 필요 시 AWS Console에서 삭제 후 재생성)

---

## 12. 다음 단계

설정 완료 후:
1. `docs/MONITORING-AND-TESTING.md` 참고하여 Failover 테스트 진행
2. CloudWatch Dashboard에서 실시간 모니터링
3. 시나리오별 테스트 수행

**문제 발생 시**: `docs/MONITORING-AND-TESTING.md`의 "6. 문제 해결" 섹션 참고
