# 인프라 구성 요약

## 네트워크 구조

### VPC
- **CIDR**: `10.0.0.0/16`
- **리전**: ap-northeast-2 (서울)
- **가용 영역**: 3개 (2a, 2b, 2c)

### Subnet 구성

#### Public Subnets (ALB, NAT Gateway)
- **Public AZ-a**: `10.0.1.0/24` (ap-northeast-2a)
- **Public AZ-b**: `10.0.2.0/24` (ap-northeast-2b)

#### Private Subnets (EC2, RDS, Lambda)
- **Private AZ-a**: `10.0.11.0/24` (ap-northeast-2a)
  - Web1, WAS1, ProxySQL-1, DB1 (EC2)
- **Private AZ-b**: `10.0.12.0/24` (ap-northeast-2b)
  - Web2, WAS2, ProxySQL-2, RDS1
- **Private AZ-c**: `10.0.13.0/24` (ap-northeast-2c)
  - RDS2

### 네트워크 구성 요소
- **Internet Gateway**: Public Subnet 인터넷 연결
- **NAT Gateway**: Private Subnet 아웃바운드 트래픽 (Public AZ-a에 배치)
- **VPC Endpoints**: SSM, SSMMessages, EC2Messages (Private Subnet에서 SSM 접속용)

## 리소스 구성

### Compute (EC2)

#### AZ-a (온프레미스 가정)
| 인스턴스 | 타입 | 역할 | AMI |
|---------|------|------|-----|
| web1 | t3.micro | Nginx | ami-08db8fe130fcdced7 |
| was1 | t3.small | Flask | ami-03ee5efafde5d6017 |
| proxysql1 | t3.small | ProxySQL | ami-09011f5b8a5d78861 |
| db1 | t3.medium | MySQL Master | ami-07ae47cb4d3d3a131 |

#### AZ-b (클라우드 전환용)
| 인스턴스 | 타입 | 역할 | AMI |
|---------|------|------|-----|
| web2 | t3.micro | Nginx | ami-08db8fe130fcdced7 |
| was2 | t3.small | Flask | ami-03ee5efafde5d6017 |
| proxysql2 | t3.small | ProxySQL | ami-09011f5b8a5d78861 |

### Database (RDS)

| 인스턴스 | 타입 | 스토리지 | 역할 | AZ |
|---------|------|---------|------|-----|
| RDS1 | db.t3.medium | 20GB gp3 | Slave → Master | 2b |
| RDS2 | db.t3.medium | 20GB gp3 | Warm Standby | 2c |

**설정:**
- Engine: MySQL 8.0
- Backup: 7일 보관
- Multi-AZ: 비활성화 (단일 AZ)

### Load Balancers

#### ALB (Application Load Balancer)
- **타입**: External (Public)
- **Subnet**: Public AZ-a, Public AZ-b
- **타겟**: Web1, Web2 (포트 80)
- **리스너**: HTTP:80

#### NLB (Network Load Balancer)
- **타입**: Internal (Private)
- **Subnet**: Private AZ-a, Private AZ-b
- **타겟**: ProxySQL-1, ProxySQL-2 (포트 6033)
- **리스너**: TCP:6033

### Serverless

#### Lambda 함수
| 함수 | 런타임 | 타임아웃 | 메모리 | VPC |
|------|--------|---------|--------|-----|
| health-monitor | Python 3.11 | 60s | 128MB | Private Subnet |
| failover-controller | Python 3.11 | 300s | 128MB | Private Subnet |

**실행 주기:**
- health-monitor: 1분마다 (CloudWatch Alarm 기반)
- failover-controller: CloudWatch Alarm 트리거

#### DynamoDB
| 테이블 | 용도 | 빌링 모드 |
|--------|------|----------|
| state | 시스템 상태 관리 | On-Demand |
| events | Failover 이벤트 로그 | On-Demand |

### Monitoring

#### CloudWatch 알람 (실시간 모니터링)
- **EC2 DB1 Health**: 3회 연속 실패 시 Failover 트리거 (1분 주기)
- **RDS1 Health**: 3회 연속 실패 시 Failover 트리거 (1분 주기)
- **RDS2 Health**: 3회 연속 실패 시 알림 (1분 주기)
- **Replication Lag**: 10초 초과 시 알림 (1분 주기)
- **RDS CPU Utilization**: 80% 초과 시 알림 (5분 주기)
- **RDS Database Connections**: 80개 초과 시 알림 (5분 주기)

#### CloudWatch Dashboard
- DB Health Status (EC2 DB1, RDS1, RDS2) - 실시간
- Replication Lag - 실시간
- RDS CPU Utilization - 5분 단위
- RDS Database Connections - 5분 단위

### Migration

#### DMS (Database Migration Service)
- **복제 인스턴스**: dms.t3.medium
- **소스**: RDS1
- **타겟**: RDS2
- **타입**: CDC (Change Data Capture)

## 보안 그룹 규칙

### ALB Security Group
```
Inbound:
  - 0.0.0.0/0:80 (HTTP)
  - 0.0.0.0/0:443 (HTTPS)
Outbound:
  - All
```

### EC2 Security Group
```
Inbound:
  - ALB SG:80 (Web만)
  - 10.0.0.0/16:5000 (WAS)
  - 10.0.0.0/16:3306 (MySQL)
  - 10.0.0.0/16:6033 (ProxySQL)
  - 10.0.0.0/16:6032 (ProxySQL Admin)
Outbound:
  - All
```

### RDS Security Group
```
Inbound:
  - 10.0.0.0/16:3306
Outbound:
  - All
```

### Lambda Security Group
```
Inbound:
  - None
Outbound:
  - All
```

### VPC Endpoints Security Group
```
Inbound:
  - 10.0.0.0/16:443
Outbound:
  - All
```

## IAM 역할

### EC2 IAM Role
- **정책**: AmazonSSMManagedInstanceCore
- **용도**: SSM Session Manager 접속

### Lambda IAM Role
- **정책**:
  - AWSLambdaBasicExecutionRole (로깅)
  - AWSLambdaVPCAccessExecutionRole (VPC 접근)
  - Custom Policy:
    - DynamoDB: GetItem, PutItem, UpdateItem, Query
    - RDS: DescribeDBInstances, ModifyDBInstance
    - SNS: Publish
    - CloudWatch: PutMetricData
    - EC2: Describe*, CreateNetworkInterface, DeleteNetworkInterface

## 비용 예상 (월간)

| 리소스 | 수량 | 예상 비용 (USD) |
|--------|------|----------------|
| EC2 (t3.micro) | 2 | ~$15 |
| EC2 (t3.small) | 4 | ~$60 |
| EC2 (t3.medium) | 1 | ~$30 |
| RDS (db.t3.medium) | 2 | ~$120 |
| NAT Gateway | 1 | ~$32 |
| ALB | 1 | ~$20 |
| NLB | 1 | ~$20 |
| DMS (dms.t3.medium) | 1 | ~$50 |
| Lambda | - | ~$5 |
| DynamoDB | - | ~$5 |
| CloudWatch | - | ~$10 |
| **총 예상 비용** | | **~$367/월** |

**비용 절감 팁:**
- 테스트 완료 후 즉시 `terraform destroy`
- NAT Gateway 대신 NAT Instance 사용 (비용 절감)
- RDS 인스턴스 타입 축소 (db.t3.small)

## 주요 엔드포인트

### 외부 접속
- **ALB DNS**: `<project-name>-alb-<random>.ap-northeast-2.elb.amazonaws.com`
- **용도**: 웹 브라우저에서 접속

### 내부 접속
- **NLB DNS**: `<project-name>-nlb-internal-<random>.elb.ap-northeast-2.amazonaws.com`
- **용도**: WAS → ProxySQL 연결

### SSM 접속
```bash
aws ssm start-session --target <instance-id>
```

## 변경 가능한 설정

### VPC CIDR 변경
**파일**: `infrastructure/terraform/variables.tf`
```hcl
variable "vpc_cidr" {
  default = "10.0.0.0/16"  # 원하는 대역으로 변경
}
```

### 인스턴스 타입 변경
**파일**: `infrastructure/terraform/main.tf`
```hcl
instances = {
  web1 = {
    instance_type = "t3.micro"  # 변경 가능
  }
}
```

### RDS 인스턴스 클래스 변경
**파일**: `infrastructure/terraform/modules/rds/main.tf`
```hcl
instance_class = "db.t3.medium"  # db.t3.small 등으로 변경 가능
```

### 가용 영역 변경
**파일**: `infrastructure/terraform/variables.tf`
```hcl
variable "availability_zones" {
  default = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
}
```

## 검토 체크리스트

- [ ] VPC CIDR 대역 확인 (`10.0.0.0/16`)
- [ ] Subnet 대역 확인 (Public: 1-2, Private: 11-13)
- [ ] 인스턴스 타입 확인 (비용 고려)
- [ ] RDS 백업 설정 확인 (7일)
- [ ] 알림 이메일 설정 (`terraform.tfvars`)
- [ ] DB 비밀번호 설정 (`terraform.tfvars`)
- [ ] AMI ID 확인 (4개 모두 올바른지)
- [ ] 리전 확인 (`ap-northeast-2`)
