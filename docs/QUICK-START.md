# 빠른 시작 가이드 (Windows PowerShell)

## 전제 조건 확인

```powershell
# 현재 디렉토리 확인
pwd

# AWS CLI 설치 확인
aws --version

# Terraform 설치 확인
terraform --version

# Python 설치 확인
python --version
```

## 1단계: Lambda 함수 빌드

### 방법 1: 수동 빌드 (PowerShell)

```powershell
# Lambda 디렉토리로 이동
cd lambda

# 빌드 디렉토리 생성
New-Item -ItemType Directory -Force -Path build
New-Item -ItemType Directory -Force -Path build\health_monitor
New-Item -ItemType Directory -Force -Path build\failover_controller

# health_monitor 빌드
Copy-Item health_monitor.py build\health_monitor\
pip install -r requirements.txt -t build\health_monitor\
Compress-Archive -Path build\health_monitor\* -DestinationPath health_monitor.zip -Force

# failover_controller 빌드
Copy-Item failover_controller.py build\failover_controller\
pip install -r requirements.txt -t build\failover_controller\
Compress-Archive -Path build\failover_controller\* -DestinationPath failover_controller.zip -Force

# 정리
Remove-Item -Recurse -Force build

# 생성된 파일 확인
ls *.zip

# 상위 디렉토리로 이동
cd ..
```

### 방법 2: 간단한 빌드 (의존성 없이)

```powershell
cd lambda

# health_monitor.zip 생성
Compress-Archive -Path health_monitor.py -DestinationPath health_monitor.zip -Force

# failover_controller.zip 생성
Compress-Archive -Path failover_controller.py -DestinationPath failover_controller.zip -Force

cd ..
```

**주의**: 방법 2는 pymysql이 포함되지 않아 Lambda 실행 시 오류가 발생할 수 있습니다. 방법 1을 권장합니다.

## 2단계: Terraform 초기화

```powershell
# Terraform 디렉토리로 이동
cd infrastructure\terraform

# terraform.tfvars 확인
cat terraform.tfvars

# Terraform 초기화 (플러그인 다운로드)
terraform init
```

**예상 출력:**
```
Initializing modules...
Initializing the backend...
Initializing provider plugins...
Terraform has been successfully initialized!
```

## 3단계: Terraform Plan (실행 계획 확인)

```powershell
# 실행 계획 확인 (어떤 리소스가 생성되는지 미리 보기)
terraform plan
```

**예상 출력:**
```
Plan: 50+ to add, 0 to change, 0 to destroy.
```

**주요 확인 사항:**
- VPC, Subnet 생성
- EC2 인스턴스 7개 생성
- RDS 인스턴스 2개 생성
- ALB, NLB 생성
- Lambda 함수 2개 생성
- DynamoDB 테이블 2개 생성

## 4단계: Terraform Apply (인프라 생성)

```powershell
# 인프라 생성 (약 15-20분 소요)
terraform apply

# 확인 메시지에서 'yes' 입력
# Do you want to perform these actions?
#   Enter a value: yes
```

**진행 상황:**
```
module.vpc.aws_vpc.main: Creating...
module.vpc.aws_vpc.main: Creation complete after 2s
module.vpc.aws_subnet.public_az_a: Creating...
...
module.rds.aws_db_instance.rds1: Still creating... [10m0s elapsed]
...
Apply complete! Resources: 50+ added, 0 changed, 0 destroyed.
```

## 5단계: 출력 값 확인

```powershell
# 모든 출력 값 확인
terraform output

# 특정 출력 값만 확인
terraform output alb_dns_name
terraform output nlb_dns_name
```

**예상 출력:**
```
alb_dns_name = "db-migration-failover-alb-1234567890.ap-northeast-2.elb.amazonaws.com"
nlb_dns_name = "db-migration-failover-nlb-internal-1234567890.elb.ap-northeast-2.amazonaws.com"
ec2_onprem_instances = {
  "db1" = "i-0123456789abcdef0"
  "proxysql1" = "i-0123456789abcdef1"
  "was1" = "i-0123456789abcdef2"
  "web1" = "i-0123456789abcdef3"
}
rds1_endpoint = "db-migration-failover-rds1.xxxxx.ap-northeast-2.rds.amazonaws.com:3306"
rds2_endpoint = "db-migration-failover-rds2.xxxxx.ap-northeast-2.rds.amazonaws.com:3306"
```

**중요**: 이 값들을 메모장에 복사해두세요!

## 6단계: 웹 브라우저에서 접속 테스트

```powershell
# ALB DNS 이름 복사
terraform output alb_dns_name

# 브라우저에서 접속
# http://<ALB_DNS_NAME>
```

**예시:**
```
http://db-migration-failover-alb-1234567890.ap-northeast-2.elb.amazonaws.com
```

**예상 화면:**
```
DB Migration Failover Test
WAS Host: was1
Connected DB Host: ip-10-0-11-xxx
Current Time: 2026-02-07 12:34:56
```

## 7단계: Private IP 확인 (설정 스크립트용)

```powershell
# EC2 DB1 Private IP 확인
aws ec2 describe-instances --instance-ids <DB1_INSTANCE_ID> --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text

# ProxySQL1 Private IP 확인
aws ec2 describe-instances --instance-ids <PROXYSQL1_INSTANCE_ID> --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text

# WAS1 Private IP 확인
aws ec2 describe-instances --instance-ids <WAS1_INSTANCE_ID> --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
```

## 8단계: SSM으로 EC2 접속

```powershell
# DB1 접속
aws ssm start-session --target <DB1_INSTANCE_ID>

# 접속 후 MySQL 확인
mysql -u admin -p
# 비밀번호: terraform.tfvars에 설정한 db_password

# 종료
exit
```

## 9단계: CloudWatch 대시보드 확인

```powershell
# AWS Console에서 확인
# CloudWatch → Dashboards → db-migration-failover-dashboard
```

또는 CLI로:
```powershell
aws cloudwatch list-dashboards
```

## 10단계: DynamoDB 상태 확인

```powershell
# 시스템 상태 조회
aws dynamodb get-item --table-name db-migration-failover-state --key '{\"pk\":{\"S\":\"SYSTEM_STATE\"},\"sk\":{\"S\":\"CURRENT\"}}'
```

**예상 출력:**
```json
{
  "Item": {
    "pk": {"S": "SYSTEM_STATE"},
    "sk": {"S": "CURRENT"},
    "ec2_db1_state": {"S": "master"},
    "rds1_state": {"S": "slave"},
    "rds2_state": {"S": "standby"},
    "current_master": {"S": "ec2_db1"},
    "ec2_db1_failure_count": {"N": "0"},
    "rds1_failure_count": {"N": "0"},
    "rds2_failure_count": {"N": "0"}
  }
}
```

## 11단계: Lambda 로그 확인

```powershell
# Health Monitor 로그 (실시간)
aws logs tail /aws/lambda/db-migration-failover-health-monitor --follow

# Failover Controller 로그
aws logs tail /aws/lambda/db-migration-failover-failover-controller --follow

# Ctrl+C로 종료
```

## 문제 해결

### Lambda ZIP 파일을 찾을 수 없음
```
Error: error creating Lambda Function: InvalidParameterValueException
```

**해결:**
```powershell
cd lambda
ls *.zip  # ZIP 파일 확인
# 없으면 1단계 다시 실행
```

### Terraform 초기화 실패
```
Error: Failed to query available provider packages
```

**해결:**
```powershell
# 프록시 설정 확인
$env:HTTP_PROXY
$env:HTTPS_PROXY

# 프록시 해제
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""

# 재시도
terraform init
```

### AMI를 찾을 수 없음
```
Error: error creating EC2 Instance: InvalidAMIID.NotFound
```

**해결:**
```powershell
# terraform.tfvars 확인
cat terraform.tfvars

# AMI ID 확인
aws ec2 describe-images --owners self --query 'Images[*].[ImageId,Name]' --output table

# terraform.tfvars 수정 후 재시도
terraform apply
```

### RDS 생성 시간 초과
```
module.rds.aws_db_instance.rds1: Still creating... [15m0s elapsed]
```

**정상입니다!** RDS는 10-15분 소요됩니다. 기다리세요.

## 정리 (테스트 완료 후)

```powershell
# 모든 리소스 삭제
terraform destroy

# 확인 메시지에서 'yes' 입력
# Do you really want to destroy all resources?
#   Enter a value: yes
```

**주의**: 이 명령은 모든 AWS 리소스를 삭제합니다!

## 시간 예상

| 단계 | 소요 시간 |
|------|----------|
| Lambda 빌드 | 2-3분 |
| Terraform init | 1분 |
| Terraform plan | 1분 |
| Terraform apply | 15-20분 |
| 접속 테스트 | 5분 |
| **총** | **약 25-30분** |

## 다음 단계

인프라 생성 완료 후:
1. MySQL 복제 설정 (`scripts/setup-mysql-replication.sh`)
2. ProxySQL 설정 (`scripts/setup-proxysql.sh`)
3. WAS/Web 설정 업데이트
4. Failover 테스트

자세한 내용은 `docs/DEPLOYMENT-GUIDE.md` 참고하세요.
