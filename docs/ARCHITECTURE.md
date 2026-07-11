# 아키텍처 문서

## 네트워크 구조

### Public Subnet
- **ALB (Application Load Balancer)**: 외부 인터넷에서 접근, Web 서버로 트래픽 전달
- **NAT Gateway**: Private Subnet의 아웃바운드 트래픽 처리

### Private Subnet
- **Web 서버 (Nginx)**: ALB에서 트래픽 수신, WAS로 프록시
- **WAS 서버 (Flask)**: 비즈니스 로직 처리, ProxySQL(NLB)을 통해 DB 접근
- **ProxySQL**: MySQL 프록시, 자동 라우팅 및 Failover
- **EC2 DB1 (MySQL)**: 온프레미스 가정, 초기 Master
- **RDS1, RDS2**: 클라우드 DB, Slave 및 Standby
- **Lambda 함수**: Failover/Rollback 로직 실행

### 접속 방법
- **외부 → Web**: ALB DNS 이름으로 접근
- **EC2 관리**: AWS Systems Manager (SSM) Session Manager 사용
- **VPC Endpoints**: SSM, SSMMessages, EC2Messages (Private Subnet에서 SSM 접속용)

## 아키텍처 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 AWS VPC                                          │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                          Public Subnets                                    │  │
│  │                                                                            │  │
│  │  ┌─────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    Internet Gateway                                  │  │  │
│  │  └──────────────────────────────┬──────────────────────────────────────┘  │  │
│  │                                 │                                          │  │
│  │                                 ▼                                          │  │
│  │                    ┌─────────────────────────┐                            │  │
│  │                    │          ALB            │                            │  │
│  │                    │  (Application LB)       │                            │  │
│  │                    └────────────┬────────────┘                            │  │
│  │                                 │                                          │  │
│  │  ┌──────────────────────────────┴──────────────────────────────┐          │  │
│  │  │                      NAT Gateway                             │          │  │
│  │  └──────────────────────────────────────────────────────────────┘          │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         Private Subnets                                    │  │
│  │                                                                            │  │
│  │  ┌───────────────────────────┐  ┌─────────────────────────┐               │  │
│  │  │         AZ-a              │  │         AZ-b            │               │  │
│  │  │     (온프레미스 가정)       │  │   (클라우드 전환용)      │               │  │
│  │  │                           │  │                         │               │  │
│  │  │  ┌─────┐ ┌─────┐         │  │  ┌─────┐ ┌─────┐       │               │  │
│  │  │  │Web1 │ │WAS1 │         │  │  │Web2 │ │WAS2 │       │               │  │
│  │  │  └──┬──┘ └──┬──┘         │  │  └──┬──┘ └──┬──┘       │               │  │
│  │  │     │       │            │  │     │       │          │               │  │
│  │  │     └───┬───┘            │  │     └───┬───┘          │               │  │
│  │  │         │                │  │         │              │               │  │
│  │  │         └────────────────┼──┼─────────┘              │               │  │
│  │  │                          │  │                        │               │  │
│  │  │                          ▼  │                        │               │  │
│  │  │                  ┌────────────────┐                  │               │  │
│  │  │                  │      NLB       │                  │               │  │
│  │  │                  │  (Internal)    │                  │               │  │
│  │  │                  └───────┬────────┘                  │               │  │
│  │  │                          │                           │               │  │
│  │  │         ┌────────────────┼────────────────┐          │               │  │
│  │  │         │                │                │          │               │  │
│  │  │         ▼                │                ▼          │               │  │
│  │  │  ┌──────────────┐        │        ┌──────────────┐  │               │  │
│  │  │  │ ProxySQL-1   │        │        │ ProxySQL-2   │  │               │  │
│  │  │  └──────┬───────┘        │        └──────┬───────┘  │               │  │
│  │  │         │                │               │          │               │  │
│  │  │         └────────────────┼───────────────┘          │               │  │
│  │  │                          │                           │               │  │
│  │  └──────────────────────────┼───────────────────────────┘               │  │
│  │                             │                                           │  │
│  │    ┌────────────────────────┼────────────────────┬──────────────────┐   │  │
│  │    │                        │                    │                  │   │  │
│  │    ▼                        │                    ▼                  ▼   │  │
│  │ ┌──────────┐                │             ┌──────────┐        ┌──────────┐ │
│  │ │ EC2 DB1  │                │             │   RDS1   │        │   RDS2   │ │
│  │ │  (AZ-a)  │                │             │  (AZ-b)  │        │  (AZ-c)  │ │
│  │ │  Master  │                │             │  Slave   │        │ Standby  │ │
│  │ └────┬─────┘                │             └────┬─────┘        └────┬─────┘ │
│  │      │                      │                  │                   │       │
│  │      │    DMS 동기화         │                  │     DMS 동기화    │       │
│  │      └──────────────────────┼──────────────────┘                   │       │
│  │                             │                                      │       │
│  │  ┌──────────────────────────┴──────────────────────────────────────┘       │
│  │  │                                                                         │
│  │  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                │
│  │  │  │ CloudWatch  │───▶│   Lambda    │───▶│  DynamoDB   │                │
│  │  │  │    알람     │    │ Failover    │    │    상태     │                │
│  │  │  └─────────────┘    │ Controller  │    └─────────────┘                │
│  │  │                     └──────┬──────┘                                    │
│  │  │                            │                                           │
│  │  │                            ▼                                           │
│  │  │                     ┌─────────────┐                                    │
│  │  │                     │     SNS     │                                    │
│  │  │                     │    알림     │                                    │
│  │  │                     └─────────────┘                                    │
│  │  │                                                                        │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  │  │              VPC Endpoints (SSM 접속용)                          │  │
│  │  │  │  - com.amazonaws.ap-northeast-2.ssm                             │  │
│  │  │  │  - com.amazonaws.ap-northeast-2.ssmmessages                     │  │
│  │  │  │  - com.amazonaws.ap-northeast-2.ec2messages                     │  │
│  │  │  └─────────────────────────────────────────────────────────────────┘  │
│  │  └────────────────────────────────────────────────────────────────────────│
│  └───────────────────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────────────┘
```

## 트래픽 흐름

### 1. 정상 상태 (EC2 DB1이 Master)
```
Internet → ALB → Web1/Web2 (Nginx) → WAS1/WAS2 (Flask) → NLB → ProxySQL-1/2 → EC2 DB1
                                                                              ↓ (DMS)
                                                                            RDS1
                                                                              ↓ (DMS)
                                                                            RDS2
```

### 2. Failover 상태 (RDS1이 Master)
```
Internet → ALB → Web1/Web2 (Nginx) → WAS1/WAS2 (Flask) → NLB → ProxySQL-1/2 → RDS1
                                                                              ↓ (DMS)
                                                                            RDS2
```

### 3. 이중 Failover 상태 (RDS2가 Master)
```
Internet → ALB → Web1/Web2 (Nginx) → WAS1/WAS2 (Flask) → NLB → ProxySQL-1/2 → RDS2
```

## 보안 그룹 규칙

### ALB Security Group
- **Inbound**: 
  - 0.0.0.0/0:80 (HTTP)
  - 0.0.0.0/0:443 (HTTPS)
- **Outbound**: All

### EC2 Security Group (Web, WAS, ProxySQL, DB1)
- **Inbound**:
  - ALB SG:80 (Web만)
  - VPC CIDR:5000 (WAS)
  - VPC CIDR:3306 (MySQL)
  - VPC CIDR:6033 (ProxySQL)
  - VPC CIDR:6032 (ProxySQL Admin)
- **Outbound**: All

### RDS Security Group
- **Inbound**: VPC CIDR:3306
- **Outbound**: All

### Lambda Security Group
- **Inbound**: None
- **Outbound**: All

### VPC Endpoints Security Group
- **Inbound**: VPC CIDR:443
- **Outbound**: All

## DynamoDB 테이블 구조

### SystemState 테이블
```json
{
  "pk": "SYSTEM_STATE",
  "sk": "CURRENT",
  "ec2_db1_state": "master|slave|failed|recovering",
  "rds1_state": "master|slave|standby|failed",
  "rds2_state": "master|standby|failed",
  "current_master": "ec2_db1|rds1|rds2",
  "replication_chain": ["ec2_db1", "rds1", "rds2"],
  "last_failover_time": "2024-01-01T00:00:00Z",
  "last_rollback_time": "2024-01-01T00:00:00Z",
  "version": 1,
  "updated_at": "2024-01-01T00:00:00Z"
}
```

### FailoverEvents 테이블
```json
{
  "pk": "FAILOVER_EVENT",
  "sk": "2024-01-01T00:00:00Z#uuid",
  "event_type": "failover|rollback",
  "from_db": "ec2_db1",
  "to_db": "rds1",
  "trigger": "health_check_failure|manual",
  "status": "initiated|in_progress|completed|failed",
  "started_at": "2024-01-01T00:00:00Z",
  "completed_at": "2024-01-01T00:00:05Z",
  "error_message": null
}
```

## SSM Session Manager 접속

Private Subnet의 EC2 인스턴스는 SSM Session Manager로 접속합니다:

```bash
# AWS CLI로 접속
aws ssm start-session --target <instance-id>

# 또는 AWS Console에서
# EC2 → Instances → 인스턴스 선택 → Connect → Session Manager
```

## 비용 최적화

- **NAT Gateway**: 단일 NAT Gateway 사용 (Multi-AZ 구성 시 추가 가능)
- **VPC Endpoints**: Interface Endpoint 사용 (NAT Gateway 트래픽 절감)
- **EC2 인스턴스**: t3 시리즈 사용 (버스트 가능)
- **RDS**: t3.medium 사용, 백업 보관 기간 7일
- **DynamoDB**: On-Demand 모드 (트래픽 예측 불가 시)

## DMS 자동 동기화 아키텍처

### DMS 복제 체인

```
DB1 (EC2) --DMS Task 1--> RDS1 --DMS Task 2--> RDS2
```

**Task 1 (DB1 → RDS1)**:
- Terraform apply 시 자동 시작
- Full Load + CDC (Change Data Capture)
- 초기 데이터 복사 + 실시간 변경사항 동기화

**Task 2 (RDS1 → RDS2)**:
- Task 1 Full Load 완료 후 Lambda가 자동 시작
- Full Load + CDC
- RDS1의 모든 데이터를 RDS2로 복제

### DMS 자동화 흐름

```
DMS Task 1 Full Load 완료
    ↓
DMS Event Subscription이 SNS로 이벤트 전송
    ↓
SNS Topic (db-failover-alerts)
    ├─→ Email 구독 (사용자) - 모든 알림 수신
    └─→ Lambda 구독 (dms_chain_starter) - DMS 이벤트만 필터링
        ↓
Lambda가 Task 2 자동 시작
    ↓
Task 2 Full Load 완료
    ↓
SNS로 "DB Synchronization Complete" 알림 전송
```

### SNS 구독 구조

**SNS Topic**: `db-failover-alerts`

**구독자 1: Email (사용자)**
- 프로토콜: Email
- 필터: 없음 (모든 알림 수신)
- 용도: 시스템 상태 모니터링

**구독자 2: Lambda (dms_chain_starter)**
- 프로토콜: Lambda
- 필터: `"Event Source" = ["replication-task"]` (DMS 이벤트만)
- 용도: Task 2 자동 시작

**구독자 3: Email (사용자) - 선택사항**
- 추가 이메일 주소 구독 가능
- 팀원들에게 알림 전송

### DMS 이벤트 종류

**state change**: Task 상태 변경 (starting, running, stopped, failed)
- Task 1 Full Load 완료 → Lambda 트리거
- Task 2 Full Load 완료 → 최종 알림

**failure**: Task 실패
- 연결 실패, 복제 오류 등

**configuration change**: Task 설정 변경
- Task 재시작, 설정 수정 등

### Lambda 자동화 로직 (dms_chain_starter.py)

```python
# SNS 메시지 파싱
sns_message = event['Records'][0]['Sns']['Message']
event_message = sns_message['Event Message']
task_arn = sns_message['Event Source ARN']

# Task 1 Full Load 완료 확인
if 'full load' in event_message.lower():
    # Task 1 상태 확인
    response = dms.describe_replication_tasks(...)
    full_load_percent = response['FullLoadProgressPercent']
    
    if full_load_percent >= 100:
        # Task 2 자동 시작
        dms.start_replication_task(
            ReplicationTaskArn=RDS1_TO_RDS2_TASK_ARN,
            StartReplicationTaskType='start-replication'
        )
```

### EventBridge 사용 현황

**DMS 자동화에서는 EventBridge를 사용하지 않습니다.**

**이유**:
- DMS는 SNS로만 이벤트를 보낼 수 있음 (AWS 제약)
- SNS → Lambda 직접 연결이 가장 간단하고 안정적

**EventBridge 사용 중인 곳**:
1. **Failover Controller Warmup** (5분마다)
   - Lambda를 warm 상태로 유지
   - Cold Start 방지

2. **Health Monitor Schedule** (1분마다)
   - DB 상태 체크 주기적 실행
   - CloudWatch 메트릭 전송

### DMS 자동화 타임라인

```
T+0분: Terraform apply 시작
T+5분: DMS Task 1 (DB1→RDS1) 자동 시작
T+10분: Task 1 Full Load 완료 (데이터 양에 따라 다름)
T+10분: DMS Event → SNS → Lambda 트리거
T+10분: Lambda가 Task 2 (RDS1→RDS2) 자동 시작
T+15분: Task 2 Full Load 완료
T+15분: "DB Synchronization Complete" 이메일 수신
```

### 수동 개입이 필요한 경우

**거의 없음!** 모든 과정이 자동화되어 있습니다.

**예외 상황**:
1. **DMS Task 실패**: Lambda가 에러 알림 전송 → 수동으로 Task 재시작
2. **SNS 구독 미확인**: 이메일 구독 확인 링크 클릭 필요 (최초 1회만)

### 데이터 무손실 보장

**Task 1 (DB1 → RDS1)**:
- Full Load: 초기 데이터 전체 복사
- CDC: 실시간 변경사항 동기화
- 복제 지연: 보통 1-2초

**Task 2 (RDS1 → RDS2)**:
- Task 1 완료 후 시작하므로 RDS1의 모든 데이터 포함
- CDC로 실시간 동기화 유지

**Failover 시**:
- RDS1, RDS2에 이미 최신 데이터 복제됨
- 데이터 유실 최소화 (마지막 1-2초만)

## CloudWatch Alarm 기반 실시간 모니터링

### 모니터링 아키텍처

시스템은 **CloudWatch Alarm**을 통해 DB 상태를 실시간으로 모니터링합니다:

```
Health Monitor Lambda (1분마다 실행)
    ↓
CloudWatch 커스텀 메트릭 전송
    ↓
CloudWatch Alarms (실시간 평가)
    ↓
SNS 알림 + Failover Controller Lambda 트리거
```

### Health Monitor Lambda

**실행 주기**: 1분마다 자동 실행

**모니터링 항목**:
1. **DB Health Check**
   - EC2 DB1, RDS1, RDS2에 MySQL 연결 테스트
   - `SELECT 1` 쿼리 실행
   - 응답 시간 측정

2. **Replication Lag**
   - Master-Slave 간 복제 지연 시간 측정
   - 10초 이상 지연 시 경고

3. **CloudWatch 메트릭 전송**
   - `DBMigration/Failover` 네임스페이스
   - `DBHealthStatus`: 1 (정상) / 0 (장애)
   - `ReplicationLag`: 초 단위 지연 시간

### CloudWatch Alarms

#### 1. EC2 DB1 Health Alarm
- **메트릭**: `DBHealthStatus` (EC2 DB1)
- **조건**: 3회 연속 실패 (< 1)
- **평가 주기**: 1분
- **액션**: SNS 알림 → Failover to RDS1

#### 2. RDS1 Health Alarm
- **메트릭**: `DBHealthStatus` (RDS1)
- **조건**: 3회 연속 실패 (< 1)
- **평가 주기**: 1분
- **액션**: SNS 알림 → Failover to RDS2

#### 3. RDS2 Health Alarm
- **메트릭**: `DBHealthStatus` (RDS2)
- **조건**: 3회 연속 실패 (< 1)
- **평가 주기**: 1분
- **액션**: SNS 알림 (Critical - 모든 DB 장애)

#### 4. Replication Lag Alarm
- **메트릭**: `ReplicationLag`
- **조건**: 10초 초과
- **평가 주기**: 1분
- **액션**: SNS 알림 (경고)

#### 5. RDS CPU Utilization Alarm
- **메트릭**: AWS/RDS `CPUUtilization`
- **조건**: 80% 초과
- **평가 주기**: 5분
- **액션**: SNS 알림

#### 6. RDS Database Connections Alarm
- **메트릭**: AWS/RDS `DatabaseConnections`
- **조건**: 80개 초과
- **평가 주기**: 5분
- **액션**: SNS 알림

### Failover 시나리오

#### 시나리오 1: EC2 DB1 장애 → RDS1 Failover
```
1. Health Monitor가 EC2 DB1 연결 실패 감지
2. CloudWatch 메트릭 전송: DBHealthStatus = 0
3. CloudWatch Alarm 트리거 (3회 연속 실패)
4. SNS 알림 발송
5. Failover Controller Lambda 실행
6. DynamoDB 상태 확인 (중복 실행 방지)
7. ProxySQL 설정 변경: Master → RDS1
8. DynamoDB 상태 업데이트
9. SNS 완료 알림
```

**소요 시간**: 약 3-4분 (3회 체크 + Failover 실행)

#### 시나리오 2: RDS1 장애 → RDS2 Failover
```
1. Health Monitor가 RDS1 연결 실패 감지
2. CloudWatch Alarm 트리거
3. Failover Controller Lambda 실행
4. ProxySQL 설정 변경: Master → RDS2
5. DMS 복제 중단 (RDS1 → RDS2)
6. 상태 업데이트 및 알림
```

#### 시나리오 3: EC2 DB1 복구 → Rollback
```
1. Health Monitor가 EC2 DB1 복구 감지
2. CloudWatch Alarm OK 상태로 전환
3. SNS OK 알림 발송
4. Failover Controller Lambda 실행
5. 복제 지연 확인 (< 10초)
6. ProxySQL 설정 변경: Master → EC2 DB1
7. 상태 업데이트 및 알림
```

#### 시나리오 4: RDS1 복구 → Rollback (EC2 DB1 여전히 장애)
```
1. Health Monitor가 RDS1 복구 감지
2. EC2 DB1 상태 확인 → 여전히 장애
3. ProxySQL 설정 변경: Master → RDS1
4. DMS 복제 재시작 (RDS1 → RDS2)
5. 상태 업데이트 및 알림
```

### CloudWatch Dashboard

실시간 모니터링 대시보드 제공:

**위젯 1: DB Health Status**
- EC2 DB1, RDS1, RDS2 상태 실시간 표시
- 1분 단위 업데이트

**위젯 2: Replication Lag**
- 복제 지연 시간 그래프
- 임계값 10초 표시

**위젯 3: RDS CPU Utilization**
- RDS1, RDS2 CPU 사용률
- 5분 단위 업데이트

**위젯 4: RDS Database Connections**
- RDS1, RDS2 연결 수
- 5분 단위 업데이트

### 실시간 모니터링의 장점

1. **빠른 장애 감지**: 1분 이내 장애 감지
2. **자동 복구**: 수동 개입 없이 자동 Failover
3. **다층 모니터링**: Health + CPU + Connections
4. **알림 통합**: SNS를 통한 이메일/SMS 알림
5. **시각화**: CloudWatch Dashboard로 실시간 확인

### 데이터 유실 최소화 메커니즘

**1분 주기 모니터링에도 데이터 유실이 최소화되는 이유:**

#### 1. 실시간 복제 (MySQL Replication)
```
EC2 DB1 (Master) → RDS1 (Slave)
    ↓ binlog 기반 실시간 복제
    ↓ 복제 지연: 보통 1초 미만
```
- 장애 발생 시 RDS1에 이미 대부분의 데이터 복제됨
- Failover 시점에 유실 가능한 데이터: 마지막 1-2초의 트랜잭션만

#### 2. 실시간 동기화 (DMS CDC)
```
RDS1 → RDS2
    ↓ Change Data Capture
    ↓ 실시간 변경사항 동기화
```

#### 3. Failover 타임라인
```
T+0초: DB 장애 발생
T+60초: Health Monitor가 장애 감지 (1차)
T+120초: 2차 체크
T+180초: 3차 체크 → CloudWatch Alarm 트리거
T+240초: Failover 완료

유실 가능 데이터: T+0 ~ T+2초 사이의 미복제 트랜잭션만
```

#### 4. 프로덕션 환경 권장사항
- **1분 주기**: 일반적인 프로덕션 환경에서 사용
- **더 빠른 감지 필요 시**: CloudWatch Logs Insights + Metric Filter 사용
- **완벽한 무손실**: Multi-AZ RDS + Synchronous Replication 사용

**현재 구조는 발표용으로 충분하며, 실제 프로덕션에서도 널리 사용되는 방식입니다.**
