# 모니터링 및 Failover 테스트 가이드

## 1. CloudWatch 모니터링

### 1.1 CloudWatch Dashboard 확인

**접속 방법**:
1. AWS Console → CloudWatch → Dashboards
2. `db-failover-dashboard` 선택

**확인할 위젯**:
- **DB Health Status**: EC2 DB1, RDS1, RDS2의 실시간 상태
  - 1 = 정상
  - 0 = 장애
- **Replication Lag**: RDS1→RDS2 복제 지연 시간 (초 단위)
- **RDS Performance**: RDS1, RDS2의 CPU 사용률
- **RDS Connections**: RDS1, RDS2의 현재 연결 수

### 1.2 CloudWatch Alarms 확인

**접속 방법**:
1. AWS Console → CloudWatch → Alarms
2. 다음 6개 알람 상태 확인

**알람 목록**:
- `db-failover-ec2-db1-health`: EC2 DB1 상태
- `db-failover-rds1-health`: RDS1 상태
- `db-failover-rds2-health`: RDS2 상태
- `db-failover-replication-lag`: 복제 지연
- `db-failover-rds1-cpu`: RDS1 CPU
- `db-failover-rds2-connections`: RDS2 연결 수

**알람 상태**:
- 초록색 (OK): 정상
- 빨간색 (ALARM): 장애 발생 → Failover 자동 실행
- 회색 (INSUFFICIENT_DATA): 데이터 부족

### 1.3 Lambda 로그 확인

**Health Monitor 로그**:
```bash
aws logs tail /aws/lambda/db-failover-health-monitor --follow
```

**Failover Controller 로그**:
```bash
aws logs tail /aws/lambda/db-failover-failover-controller --follow
```

확인할 내용:
- DB 연결 성공/실패
- 메트릭 전송 여부
- Failover 실행 시나리오
- ProxySQL 설정 변경 내역

## 2. 데이터베이스 직접 확인

### 2.1 EC2 MySQL (DB1) 접속

```bash
# SSM Session Manager로 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 접속
mysql -u admin -ptest123!

# 데이터베이스 선택
USE toydb;

# 테이블 목록 확인
SHOW TABLES;

# 사용자 데이터 조회
SELECT * FROM users ORDER BY created_at DESC;

# 특정 사용자 검색
SELECT * FROM users WHERE name LIKE '%홍길동%';

# 데이터 개수 확인
SELECT COUNT(*) FROM users;

# 최근 생성된 데이터 5개
SELECT * FROM users ORDER BY created_at DESC LIMIT 5;

# 종료
exit
```

### 2.2 RDS1 접속

```bash
# ProxySQL 또는 WAS EC2에서 접속
aws ssm start-session --target <PROXYSQL_INSTANCE_ID>

# RDS1 엔드포인트로 접속
mysql -u admin -ptest123! -h <RDS1_ENDPOINT>

# 동일한 쿼리 실행
USE toydb;
SELECT * FROM users;
exit
```

### 2.3 RDS2 접속

```bash
# RDS2 엔드포인트로 접속
mysql -u admin -ptest123! -h <RDS2_ENDPOINT>

# 복제 상태 확인
SHOW SLAVE STATUS\G

# 데이터 확인
USE toydb;
SELECT * FROM users;
exit
```

### 2.4 ProxySQL 상태 확인

**ProxySQL에서는 mysql 클라이언트가 설치되지 않았으므로, WAS나 DB1에서 원격으로 접속합니다.**

```bash
# WAS 또는 DB1 접속 (mysql 클라이언트 있음)
aws ssm start-session --target <WAS_OR_DB1_INSTANCE_ID>

# ProxySQL Private IP 확인
# ProxySQL1: <PROXYSQL1_PRIVATE_IP>
# ProxySQL2: <PROXYSQL2_PRIVATE_IP>

# ProxySQL Admin 접속 (WAS/DB1에서)
mysql -u admin -padmin -h <PROXYSQL_PRIVATE_IP> -P 6032

# 백엔드 서버 상태 확인
SELECT * FROM mysql_servers;

# 현재 활성 연결 확인
SELECT * FROM stats_mysql_connection_pool;

# 쿼리 통계 확인
SELECT * FROM stats_mysql_query_digest ORDER BY sum_time DESC LIMIT 10;

exit
```

확인할 항목:
- `status`: ONLINE (활성), OFFLINE_SOFT (비활성)
- `hostgroup_id`: 10 (Writer), 20 (Reader)

**또는 ProxySQL 설정 파일로 확인**:
```bash
# ProxySQL 접속
aws ssm start-session --target <PROXYSQL_INSTANCE_ID>

# 설정 파일 확인
sudo cat /etc/proxysql.cnf | grep -A 10 mysql_servers
sudo cat /etc/proxysql.cnf | grep -A 10 mysql_users

# ProxySQL 로그 확인
sudo tail -f /var/lib/proxysql/proxysql.log

# ProxySQL 상태
sudo systemctl status proxysql
```

## 3. DynamoDB 상태 확인

### 3.1 현재 Failover 상태 조회

```bash
# 현재 상태 확인
aws dynamodb get-item \
  --table-name db-failover-state \
  --key '{"id":{"S":"current_state"}}'
```

**확인할 항목**:
- `current_db`: 현재 활성 DB (ec2_db1, rds1, rds2)
- `last_failover_time`: 마지막 Failover 시간
- `failover_count`: Failover 발생 횟수

### 3.2 전체 상태 스캔

```bash
aws dynamodb scan --table-name db-failover-state
```

## 4. Failover 시나리오 테스트

### 시나리오 1: EC2 DB1 장애 → RDS1 Failover

**1. 사전 확인**:
```bash
# CloudWatch Dashboard 확인
# - 모든 DB Health = 1 (정상)

# DynamoDB 상태 확인
aws dynamodb get-item \
  --table-name db-failover-state \
  --key '{"id":{"S":"current_state"}}'
# 예상: current_db = "ec2_db1"

# 웹사이트 접속
# ALB DNS: http://<ALB_DNS_NAME>
# Connected DB Host: EC2 DB1 호스트명 확인
```

**2. 장애 발생 (DB1 중지)**:
```bash
# DB1 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 중지
sudo systemctl stop mysql

# 상태 확인
sudo systemctl status mysql
```

**3. 모니터링 (3분 대기)**:
```bash
# CloudWatch Alarm 확인
# - db-failover-ec2-db1-health 알람이 빨간색으로 변경 (3분 후)

# Lambda 로그 실시간 확인
aws logs tail /aws/lambda/db-failover-failover-controller --follow

# DynamoDB 상태 확인 (Failover 완료 후)
aws dynamodb get-item \
  --table-name db-failover-state \
  --key '{"id":{"S":"current_state"}}'
# 예상: current_db = "rds1"
```

**4. 결과 확인**:
```bash
# 웹사이트 새로고침
# Connected DB Host: RDS1 호스트명으로 변경 확인

# RDS1에서 데이터 확인
mysql -u admin -ptest123! -h <RDS1_ENDPOINT>
USE toydb;
SELECT * FROM users;
```

**5. 데이터 무손실 확인**:
- 웹사이트에서 새 데이터 입력
- RDS1에서 데이터 조회하여 정상 저장 확인
- Failover 중에도 데이터 입력/조회 가능

### 시나리오 2: Rollback (RDS1 → EC2 DB1)

**동작 방식**: Lambda Failover Controller가 자동으로 역방향 복제를 설정하여 RDS1의 데이터를 DB1로 동기화한 후 Rollback을 수행합니다.

**1. DB1 복구**:
```bash
# DB1 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# MySQL 재시작
sudo systemctl start mysql
sudo systemctl status mysql
```

**2. 모니터링 (3분 대기)**:
```bash
# CloudWatch Alarm 확인
# - db-failover-ec2-db1-health 알람이 초록색으로 복구

# Lambda 로그 확인
aws logs tail /aws/lambda/db-failover-failover-controller --follow

# DynamoDB 상태 확인
aws dynamodb get-item \
  --table-name db-failover-state \
  --key '{"id":{"S":"current_state"}}'
# 예상: current_db = "ec2_db1"
```

**3. 결과 확인**:
```bash
# 웹사이트 새로고침
# Connected DB Host: EC2 DB1 호스트명으로 복귀 확인

# DB1에서 데이터 확인 (RDS1에서 입력한 데이터도 동기화됨)
mysql -u admin -ptest123! -h <DB1_PRIVATE_IP>
USE toydb;
SELECT * FROM users ORDER BY created_at DESC LIMIT 10;
```

**4. 데이터 동기화 확인**:
- Failover 중 RDS1에 입력한 데이터가 DB1에도 존재하는지 확인
- Lambda가 자동으로 역방향 복제를 설정하여 데이터 손실 방지

### 시나리오 3: RDS1 장애 → RDS2 Failover

**1. RDS1 중지**:
```bash
# RDS1 인스턴스 중지
aws rds stop-db-instance --db-instance-identifier db-failover-rds1
```
**2. RDS 복구**:
```bash
# RDS 인스턴스 복구
aws rds start-db-instance --db-instance-identifier db-failover-rds1


**2. 모니터링 (3분 대기)**:
```bash
# CloudWatch Alarm 확인
# - db-failover-rds1-health 알람이 빨간색으로 변경

# DynamoDB 상태 확인
aws dynamodb get-item \
  --table-name db-failover-state \
  --key '{"id":{"S":"current_state"}}'
# 예상: current_db = "rds2"
```

**3. 결과 확인**:
```bash
# 웹사이트 새로고침
# Connected DB Host: RDS2 호스트명으로 변경 확인
```

### 시나리오 4: 복제 지연 알람

**1. 복제 지연 확인**:
```bash
# RDS1에서 복제 상태 확인
mysql -u admin -ptest123! -h <RDS1_ENDPOINT>
SHOW SLAVE STATUS\G
# Seconds_Behind_Master 값 확인
```

**2. CloudWatch Alarm 확인**:
- `db-failover-replication-lag` 알람 상태 확인
- 10초 이상 지연 시 알람 발생

## 5. 발표 시 보여줄 포인트

### 5.1 실시간 모니터링
- CloudWatch Dashboard에서 DB Health Status 실시간 변화
- 알람이 빨간색으로 변경되는 순간 캡처

### 5.2 자동 Failover
- Lambda 로그에서 Failover 실행 과정 보여주기
- DynamoDB에서 current_db 변경 확인

### 5.3 데이터 무손실
- Failover 전후 데이터 비교
- 웹사이트에서 계속 정상 작동하는 모습

### 5.4 투명성
- 사용자는 Failover를 인지하지 못함
- 웹사이트 계속 작동 (Connected DB Host만 변경)

### 5.5 자동 복구
- DB 복구 시 자동 Rollback
- 수동 개입 없이 모든 과정 자동 실행

## 6. 문제 해결

### 6.1 Failover가 실행되지 않을 때

```bash
# Lambda 함수 수동 실행
aws lambda invoke \
  --function-name db-failover-health-monitor \
  --payload '{}' \
  response.json

# 로그 확인
aws logs tail /aws/lambda/db-failover-health-monitor --follow
```

### 6.2 ProxySQL 연결 문제

**ProxySQL에서 mysql 명령어가 안될 때**:
- ProxySQL 인스턴스에는 mysql 클라이언트가 설치되지 않았습니다
- **해결 방법**: WAS 또는 DB1에서 원격으로 ProxySQL Admin에 접속

```bash
# WAS 또는 DB1 접속
aws ssm start-session --target <WAS_OR_DB1_INSTANCE_ID>

# ProxySQL Admin 원격 접속
mysql -u admin -padmin -h <PROXYSQL_PRIVATE_IP> -P 6032

# 백엔드 서버 확인
SELECT * FROM mysql_servers;
exit
```

**ProxySQL 설정 파일 직접 수정**:
```bash
# ProxySQL 접속
aws ssm start-session --target <PROXYSQL_INSTANCE_ID>

# 설정 파일 수정
sudo vi /etc/proxysql.cnf

# ProxySQL 재시작
sudo systemctl restart proxysql

# 로그 확인
sudo tail -f /var/lib/proxysql/proxysql.log
```

### 6.3 웹사이트 접속 불가

```bash
# Target Group Health 확인
aws elbv2 describe-target-health --target-group-arn <TARGET_GROUP_ARN>

# Nginx 상태 확인
aws ssm start-session --target <WEB_INSTANCE_ID>
sudo systemctl status nginx

# Flask 상태 확인
aws ssm start-session --target <WAS_INSTANCE_ID>
sudo systemctl status flask-app
```

## 7. 정리 (테스트 완료 후)

```bash
# 모든 리소스 삭제
cd infrastructure/terraform
terraform destroy
```

**주의**: 이 명령은 모든 AWS 리소스를 삭제합니다. 데이터가 영구적으로 삭제됩니다.
