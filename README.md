# DB 클라우드 마이그레이션 Failover 시스템

온프레미스 환경에서 클라우드로의 점진적 DB 마이그레이션을 위한 고가용성 Failover 시스템입니다.

## 아키텍처 개요

- **온프레미스 가정 (AZ-a)**: Web1, WAS1, ProxySQL-1, EC2 DB1 (Master)
- **클라우드 전환용 (AZ-b)**: Web2, WAS2, ProxySQL-2, RDS1 (Slave)
- **Warm Standby (AZ-d)**: RDS2 (DMS 동기화)

## 빠른 시작 (7시간 완료 목표)

### 1단계: VM 준비 (2시간)

VM Workstation에서 Ubuntu 24.04 기반 4개 VM 생성:

1. **Web VM (Nginx)**
   ```bash
   sudo apt update
   sudo apt install -y nginx
   # nginx.conf 파일 복사
   sudo systemctl enable nginx
   ```

2. **WAS VM (Flask)**
   ```bash
   sudo apt update
   sudo apt install -y python3 python3-pip
   pip3 install flask mysql-connector-python
   # app.py 파일 복사
   ```

3. **ProxySQL VM**
   ```bash
   sudo apt update
   wget https://github.com/sysown/proxysql/releases/download/v2.5.5/proxysql_2.5.5-ubuntu24_amd64.deb
   sudo dpkg -i proxysql_2.5.5-ubuntu24_amd64.deb
   sudo systemctl enable proxysql
   ```

4. **MySQL VM (DB1)**
   ```bash
   sudo apt update
   sudo apt install -y mysql-server
   # MySQL 설정 (GTID, 바이너리 로그)
   sudo systemctl enable mysql
   ```

**중요**: 각 VM의 네트워크 설정을 DHCP로 변경:
```bash
sudo nano /etc/netplan/00-installer-config.yaml
# dhcp4: true로 변경
sudo netplan apply
```

### 2단계: VM을 OVA로 내보내기 (30분)

VM Workstation에서:
1. 각 VM 종료
2. File → Export to OVF/OVA
3. OVA 형식 선택
4. 저장 위치 지정

### 3단계: AWS로 VM Import (1시간)

```bash
cd scripts
chmod +x vm-import.sh

# 각 VM을 순차적으로 Import
./vm-import.sh web /path/to/web.ova
./vm-import.sh was /path/to/was.ova
./vm-import.sh proxysql /path/to/proxysql.ova
./vm-import.sh mysql /path/to/mysql.ova
```

생성된 AMI ID를 `ami-ids.txt`에서 확인하고 Terraform 변수에 입력합니다.

### 4단계: Terraform으로 인프라 구축 (1.5시간)

```bash
cd infrastructure/terraform

# 변수 파일 생성
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars  # AMI ID와 기타 변수 입력

# Terraform 초기화 및 실행
terraform init
terraform plan
terraform apply
```

### 5단계: MySQL 복제 설정 (30분)

```bash
# EC2 DB1에서 Master 설정
cd scripts
./setup-mysql-master.sh

# RDS1에서 Slave 설정
./setup-mysql-slave.sh
```

### 6단계: ProxySQL 설정 (30분)

```bash
# ProxySQL 백엔드 서버 및 라우팅 규칙 설정
./setup-proxysql.sh
```

### 7단계: Lambda 함수 배포 (30분)

```bash
cd lambda
./build-and-deploy.sh
```

### 8단계: 테스트 및 검증 (30분)

```bash
# Failover 테스트
./test-failover.sh

# 대시보드 확인
# AWS Console → CloudWatch → Dashboards
```

### 9단계: PPT 작성 (30분)

주요 내용:
- 아키텍처 다이어그램
- Failover 시나리오 (EC2 DB1 → RDS1 → RDS2)
- 데모 스크린샷
- 구현 결과

## 디렉토리 구조

```
.
├── infrastructure/
│   └── terraform/          # Terraform IaC 코드
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── modules/        # 모듈별 리소스
├── lambda/                 # Lambda 함수 코드
│   ├── health_monitor.py
│   ├── failover_controller.py
│   └── replication_manager.py
├── scripts/                # 설정 스크립트
│   ├── vm-import.sh
│   ├── setup-mysql-master.sh
│   ├── setup-mysql-slave.sh
│   └── setup-proxysql.sh
├── app.py                  # Flask WAS 애플리케이션
├── nginx.conf              # Nginx 설정
└── README.md
```

## 주요 기능

1. **ProxySQL 기반 자동 라우팅**: WAS는 ProxySQL만 바라보며, 백엔드 DB 변경 시 자동 전환
2. **3단계 Failover 체인**: EC2 DB1 → RDS1 → RDS2
3. **자동 Rollback**: EC2 DB1 복구 시 자동으로 Master 역할 복귀
4. **CloudWatch 모니터링**: 실시간 DB 상태 및 복제 지연 모니터링
5. **Lambda 자동화**: 무인 Failover/Rollback 실행

## 문제 해결

### VM Import 실패
- OVA 파일 크기 확인 (최대 10GB 권장)
- IAM 역할 권한 확인
- S3 버킷 리전 확인

### Terraform 오류
- AMI ID가 올바른지 확인
- AWS 자격 증명 확인 (`aws configure`)
- 리전 설정 확인

### MySQL 복제 오류
- 네트워크 연결 확인
- 방화벽 규칙 확인 (포트 3306)
- GTID 설정 확인

## 참고 문서

- [AWS VM Import/Export](https://docs.aws.amazon.com/vm-import/latest/userguide/what-is-vmimport.html)
- [ProxySQL Documentation](https://proxysql.com/documentation/)
- [MySQL GTID Replication](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids.html)
- [AWS DMS](https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html)
