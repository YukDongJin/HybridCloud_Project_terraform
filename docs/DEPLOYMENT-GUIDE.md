# 배포 가이드

## 전제 조건

- ✅ VM 4개 (Web, WAS, ProxySQL, MySQL) OVA 파일 준비 완료
- ✅ AWS CLI 설치 및 구성 (`aws configure`)
- ✅ Terraform 설치 (v1.0 이상)
- ✅ Python 3.11 설치 (Lambda 빌드용)

## 1단계: VM Import (완료)

VM을 AWS AMI로 변환합니다.

```bash
cd scripts

# 각 VM을 순차적으로 Import
./vm-import.sh web /path/to/web.ova
./vm-import.sh was /path/to/was.ova
./vm-import.sh proxysql /path/to/proxysql.ova
./vm-import.sh mysql /path/to/mysql.ova
```

생성된 AMI ID를 `ami-ids.txt`에서 확인합니다.

## 2단계: Lambda 함수 빌드

```bash
cd lambda

# 의존성 설치 및 ZIP 파일 생성
chmod +x build.sh
./build.sh

# 생성된 파일 확인
ls -lh *.zip
# health_monitor.zip
# failover_controller.zip
```

## 3단계: Terraform 변수 설정

```bash
cd infrastructure/terraform

# 변수 파일 생성
cp terraform.tfvars.example terraform.tfvars

# 변수 파일 편집
nano terraform.tfvars
```

`terraform.tfvars` 내용:
```hcl
aws_region = "ap-northeast-2"
project_name = "db-migration-failover"

# VM Import에서 생성된 AMI ID 입력
web_ami_id      = "ami-xxxxxxxxxxxxx"  # ami-ids.txt에서 복사
was_ami_id      = "ami-xxxxxxxxxxxxx"
proxysql_ami_id = "ami-xxxxxxxxxxxxx"
mysql_ami_id    = "ami-xxxxxxxxxxxxx"

# 데이터베이스 자격 증명
db_username = "admin"
db_password = "YourSecurePassword123!"  # 강력한 비밀번호로 변경

# 알림 이메일
notification_email = "your-email@example.com"
```

## 4단계: Terraform 실행

```bash
# Terraform 초기화
terraform init

# 실행 계획 확인
terraform plan

# 인프라 생성 (약 15-20분 소요)
terraform apply
```

주요 리소스 생성 시간:
- VPC, Subnet, NAT Gateway: 2-3분
- EC2 인스턴스: 3-5분
- RDS 인스턴스: 10-15분
- Lambda, DynamoDB, CloudWatch: 2-3분

## 5단계: 출력 값 확인

Terraform 완료 후 출력 값을 확인합니다:

```bash
terraform output
```

출력 예시:
```
alb_dns_name = "db-migration-failover-alb-1234567890.ap-northeast-2.elb.amazonaws.com"
nlb_dns_name = "db-migration-failover-nlb-internal-1234567890.elb.ap-northeast-2.amazonaws.com"
ec2_onprem_instances = {
  db1 = "i-xxxxxxxxxxxxx"
  proxysql1 = "i-xxxxxxxxxxxxx"
  was1 = "i-xxxxxxxxxxxxx"
  web1 = "i-xxxxxxxxxxxxx"
}
rds1_endpoint = "db-migration-failover-rds1.xxxxxxxxxxxxx.ap-northeast-2.rds.amazonaws.com:3306"
rds2_endpoint = "db-migration-failover-rds2.xxxxxxxxxxxxx.ap-northeast-2.rds.amazonaws.com:3306"
```

이 값들을 메모장에 저장해두세요.

## 6단계: MySQL 복제 설정

```bash
cd ../../scripts

# 환경 변수 설정
export EC2_DB1_IP="<EC2 DB1 Private IP>"
export RDS1_ENDPOINT="<RDS1 Endpoint (포트 제외)>"
export DB_PASSWORD="YourSecurePassword123!"
export REPL_PASSWORD="repl_password123"

# 복제 설정 실행
chmod +x setup-mysql-replication.sh
./setup-mysql-replication.sh
```

**Private IP 확인 방법:**
```bash
# Terraform output에서 인스턴스 ID 확인 후
aws ec2 describe-instances --instance-ids i-xxxxxxxxxxxxx \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

## 7단계: ProxySQL 설정

### 방법 1: 스크립트 사용 (권장)
```bash
# 환경 변수 설정
export PROXYSQL_IP="<ProxySQL1 Private IP>"
export EC2_DB1_IP="<EC2 DB1 Private IP>"
export RDS1_ENDPOINT="<RDS1 Endpoint (포트 제외)>"
export RDS2_ENDPOINT="<RDS2 Endpoint (포트 제외)>"
export DB_PASSWORD="YourSecurePassword123!"

# ProxySQL 설정 실행
chmod +x setup-proxysql.sh
./setup-proxysql.sh
```

### 방법 2: 설정 파일 직접 수정 (mysql 클라이언트 없을 때)

```bash
# ProxySQL 접속
aws ssm start-session --target <ProxySQL Instance ID>

# 설정 파일 편집
sudo nano /etc/proxysql.cnf
```

**1. mysql_users 섹션에 was_user 추가**:
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

**2. mysql_servers 섹션 수정 (중요!)**:

로컬 VM 설정(`127.0.0.1` 또는 Unix 소켓)을 AWS Private IP로 변경:

```
mysql_servers =
(
    {
        address = "<EC2_DB1_PRIVATE_IP>"  # 예: 10.0.12.252
        port = 3306
        hostgroup = 10
        status = "ONLINE"
        weight = 1
        compression = 0
        max_replication_lag = 10
    }
)
```

**EC2 DB1 Private IP 확인**:
```bash
aws ec2 describe-instances --instance-ids <DB1_INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

**ProxySQL 재시작**:
```bash
sudo systemctl restart proxysql
sudo systemctl status proxysql
```

### 문제 해결: Access Denied 에러 발생 시

ProxySQL 로그에서 Access Denied 에러가 계속 발생하면 다음 단계를 수행하세요.

**1. ProxySQL 설정 정리 (불필요한 서버 제거)**:
```bash
# ProxySQL 접속
aws ssm start-session --target <ProxySQL Instance ID>

# 설정 파일 확인
sudo cat /etc/proxysql.cnf | grep -B 2 -A 5 "address ="

# 설정 파일 편집
sudo nano /etc/proxysql.cnf
```

mysql_servers 섹션을 단순하게 (DB1만 남기기):
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

**2. ProxySQL DB 초기화 (캐시 삭제)**:
```bash
# ProxySQL 중지
sudo systemctl stop proxysql

# 기존 DB 삭제 (설정 초기화)
sudo rm -f /var/lib/proxysql/proxysql.db

# 재시작 (conf 파일에서 새로 로드)
sudo systemctl start proxysql
sudo systemctl status proxysql
```

**3. DB1에서 was_user 재설정**:
```bash
# DB1 접속
aws ssm start-session --target <DB1 Instance ID>

# MySQL 접속
sudo mysql

# was_user 재생성 (mysql_native_password 플러그인 사용)
DROP USER IF EXISTS 'was_user'@'%';
CREATE USER 'was_user'@'%' IDENTIFIED WITH mysql_native_password BY 'test1234';
GRANT ALL PRIVILEGES ON toydb.* TO 'was_user'@'%';
FLUSH PRIVILEGES;

# 확인
SELECT user, host, plugin FROM mysql.user WHERE user='was_user';
exit
```

**4. WAS Flask 재시작**:
```bash
# WAS 접속
aws ssm start-session --target <WAS Instance ID>

# Flask 재시작
sudo systemctl restart flask-app
sudo systemctl status flask-app
```

**5. 웹사이트 테스트**:
브라우저에서 ALB DNS 주소로 접속하여 정상 작동 확인

## 8단계: WAS 설정 업데이트

SSM Session Manager로 WAS 인스턴스에 접속하여 app.py를 업데이트합니다.

```bash
# WAS 접속
aws ssm start-session --target <WAS Instance ID>

# app.py 수정 (NLB DNS 이름으로 변경)
nano /home/ubuntu/app/app.py
```

`app.py`에서 host 부분 수정:
```python
host="<NLB_DNS_NAME>",  # Terraform output의 nlb_dns_name
port=6033,
```

**Flask 재시작:**
```bash
# systemd 서비스 재시작
sudo systemctl restart flask-app

# 상태 확인
sudo systemctl status flask-app

# 5000번 포트 확인
netstat -tlnp | grep :5000
```

WAS1, WAS2 모두 동일하게 설정합니다.

## 9단계: DMS 태스크 시작

```bash
# DMS 복제 태스크 ARN 확인
aws dms describe-replication-tasks \
  --filters "Name=replication-task-id,Values=db-migration-failover-rds1-to-rds2" \
  --query 'ReplicationTasks[0].ReplicationTaskArn' \
  --output text

# 태스크 시작
aws dms start-replication-task \
  --replication-task-arn <TASK_ARN> \
  --start-replication-task-type start-replication
```

## 10단계: 동작 확인

### 1. ALB를 통한 웹 접속 테스트

```bash
# ALB DNS 이름으로 접속
curl http://<ALB_DNS_NAME>
```

브라우저에서 접속하면 다음 정보가 표시됩니다:
- WAS Host: was1 또는 was2
- Connected DB Host: EC2 DB1 호스트명
- Current Time: 현재 시간

### 2. CloudWatch 대시보드 확인

AWS Console → CloudWatch → Dashboards → `db-migration-failover-dashboard`

확인 항목:
- DB Health Status (EC2 DB1, RDS1, RDS2)
- Replication Lag
- Query Latency

### 3. DynamoDB 상태 확인

```bash
aws dynamodb get-item \
  --table-name db-migration-failover-state \
  --key '{"pk":{"S":"SYSTEM_STATE"},"sk":{"S":"CURRENT"}}'
```

예상 출력:
```json
{
  "ec2_db1_state": "master",
  "rds1_state": "slave",
  "rds2_state": "standby",
  "current_master": "ec2_db1"
}
```

## 11단계: Failover 테스트

### 수동 Failover 테스트

```bash
# EC2 DB1 중지 (Failover 트리거)
aws ec2 stop-instances --instance-ids <EC2_DB1_INSTANCE_ID>

# CloudWatch 로그 확인 (약 30초 후)
aws logs tail /aws/lambda/db-migration-failover-health-monitor --follow

# Failover 완료 확인 (약 1분 후)
aws dynamodb get-item \
  --table-name db-migration-failover-state \
  --key '{"pk":{"S":"SYSTEM_STATE"},"sk":{"S":"CURRENT"}}'
```

예상 결과:
```json
{
  "ec2_db1_state": "failed",
  "rds1_state": "master",
  "current_master": "rds1"
}
```

웹 페이지 새로고침 시 "Connected DB Host"가 RDS1으로 변경됩니다.

## 문제 해결

### Lambda 함수 로그 확인

```bash
# Health Monitor 로그
aws logs tail /aws/lambda/db-migration-failover-health-monitor --follow

# Failover Controller 로그
aws logs tail /aws/lambda/db-migration-failover-failover-controller --follow
```

### ProxySQL 상태 확인

```bash
# ProxySQL 접속
aws ssm start-session --target <ProxySQL1_INSTANCE_ID>

# ProxySQL Admin 접속
mysql -h 127.0.0.1 -P 6032 -u admin -padmin

# 백엔드 서버 상태 확인
SELECT * FROM mysql_servers;

# 연결 통계 확인
SELECT * FROM stats_mysql_connection_pool;
```

### MySQL 복제 상태 확인

```bash
# RDS1 복제 상태
mysql -h <RDS1_ENDPOINT> -u admin -p<PASSWORD> -e "SHOW SLAVE STATUS\G"
```

## 정리 (테스트 완료 후)

```bash
cd infrastructure/terraform

# 모든 리소스 삭제
terraform destroy
```

**주의**: 이 명령은 모든 AWS 리소스를 삭제합니다. 데이터가 영구적으로 삭제됩니다.

## 다음 단계

- PPT 작성 (아키텍처 다이어그램, Failover 시나리오, 데모 스크린샷)
- 발표 준비
