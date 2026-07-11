# 설계 문서: DB 클라우드 마이그레이션 Failover

## 개요

이 시스템은 온프레미스(EC2 DB1)에서 클라우드(RDS)로의 점진적 DB 마이그레이션을 지원하는 고가용성 Failover 솔루션입니다. ProxySQL을 프록시 레이어로 사용하여 WAS의 코드 변경 없이 자동 Failover/Rollback을 구현합니다.

### 핵심 설계 원칙
- **투명성**: WAS는 ProxySQL만 바라보며, 백엔드 DB 변경을 인지하지 않음
- **자동화**: CloudWatch + Lambda로 무인 Failover/Rollback
- **일관성**: GTID 기반 복제로 데이터 일관성 보장
- **복원력**: 3단계 Failover 체인 (EC2 DB1 → RDS1 → RDS2)
- **점진적 전환**: 온프레미스에서 클라우드로 단계적 마이그레이션

### 인프라 배치 (Multi-AZ)

| 가용 영역 | 역할 | 구성 요소 |
|----------|------|----------|
| AZ-a | 온프레미스 가정 | Web1, WAS1, EC2 DB1 (Master), ProxySQL-1 (EC2) |
| AZ-b | 클라우드 마이그레이션용 | Web2, WAS2, RDS1 (Slave), ProxySQL-2 (EC2) |
| AZ-d | Warm Standby | RDS2 (DMS 동기화) |

**ProxySQL 고가용성 구성:**
- ProxySQL-1: AZ-a에 배치 (온프레미스 가정, Primary)
- ProxySQL-2: AZ-b에 배치 (클라우드 전환용, Standby)
- NLB: 두 ProxySQL 앞에 배치, 헬스체크 기반 자동 전환
- WAS1, WAS2 모두 NLB 엔드포인트를 통해 DB 접근

**ProxySQL Failover 시나리오:**
1. 정상 상태: NLB → ProxySQL-1 (AZ-a) → EC2 DB1
2. AZ-a 장애: NLB → ProxySQL-2 (AZ-b) → RDS1

### 점진적 전환 전략
1. **1단계**: 온프레미스 가정(AZ-a)에서 운영, RDS1/RDS2는 복제 대기
2. **2단계**: EC2 DB1 장애 시 RDS1로 Failover (클라우드 전환)
3. **3단계**: RDS1 장애 시 RDS2로 Failover (이중 장애 대응)

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 AWS VPC                                          │
│                                                                                  │
│  ┌───────────────────────────┐  ┌─────────────────────────┐  ┌───────────────┐  │
│  │         AZ-a              │  │         AZ-b            │  │     AZ-d      │  │
│  │     (온프레미스 가정)       │  │   (클라우드 전환용)      │  │(Warm Standby) │  │
│  │                           │  │                         │  │               │  │
│  │  ┌─────┐ ┌─────┐         │  │  ┌─────┐ ┌─────┐       │  │               │  │
│  │  │Web1 │ │WAS1 │         │  │  │Web2 │ │WAS2 │       │  │               │  │
│  │  └──┬──┘ └──┬──┘         │  │  └──┬──┘ └──┬──┘       │  │               │  │
│  │     │       │            │  │     │       │          │  │               │  │
│  │     └───┬───┘            │  │     └───┬───┘          │  │               │  │
│  │         │                │  │         │              │  │               │  │
│  └─────────┼────────────────┘  └─────────┼──────────────┘  └───────────────┘  │
│            │                             │                                     │
│            └──────────┬──────────────────┘                                     │
│                       │                                                        │
│                       ▼                                                        │
│              ┌─────────────────┐                                               │
│              │       NLB       │                                               │
│              │  (Network LB)   │                                               │
│              └────────┬────────┘                                               │
│                       │                                                        │
│         ┌─────────────┴─────────────┐                                          │
│         │                           │                                          │
│         ▼                           ▼                                          │
│  ┌─────────────────┐      ┌─────────────────┐                                  │
│  │   ProxySQL-1    │      │   ProxySQL-2    │                                  │
│  │    (AZ-a)       │      │    (AZ-b)       │                                  │
│  │   Primary       │      │   Standby       │                                  │
│  └────────┬────────┘      └────────┬────────┘                                  │
│           │                        │                                           │
│           └────────────┬───────────┘                                           │
│                        │                                                       │
│    ┌───────────────────┼───────────────────┬───────────────────┐              │
│    │                   │                   │                   │              │
│    ▼                   │                   ▼                   ▼              │
│ ┌──────────┐           │            ┌──────────┐        ┌──────────┐          │
│ │ EC2 DB1  │           │            │   RDS1   │        │   RDS2   │          │
│ │  (AZ-a)  │           │            │  (AZ-b)  │        │  (AZ-d)  │          │
│ │  Master  │           │            │  Slave   │        │ Standby  │          │
│ └────┬─────┘           │            └────┬─────┘        └────┬─────┘          │
│      │                 │                 │                   │                │
│      │    MySQL 복제   │                 │     DMS 동기화    │                │
│      └─────────────────┼─────────────────┘                   │                │
│                        │                                     │                │
│  ┌─────────────────────┴─────────────────────────────────────┘                │
│  │                                                                            │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                    │
│  │  │ CloudWatch  │───▶│   Lambda    │───▶│  DynamoDB   │                    │
│  │  │    알람     │    │ Failover    │    │    상태     │                    │
│  │  └─────────────┘    │ Controller  │    └─────────────┘                    │
│  │                     └──────┬──────┘                                        │
│  │                            │                                               │
│  │                            ▼                                               │
│  │                     ┌─────────────┐                                        │
│  │                     │     SNS     │                                        │
│  │                     │    알림     │                                        │
│  │                     └─────────────┘                                        │
│  └────────────────────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────────────┘
```

## 컴포넌트 및 인터페이스

### 1. ProxySQL 레이어

ProxySQL은 WAS와 DB 사이의 프록시로, 자동 라우팅과 헬스체크를 담당합니다.

```sql
-- ProxySQL 서버 그룹 구성
-- hostgroup 10: Writer (Master)
-- hostgroup 20: Reader (Slave)

-- 백엔드 서버 등록
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight, max_connections)
VALUES 
  (10, 'ec2-db1.internal', 3306, 1000, 100),  -- Master (AZ-a)
  (20, 'rds1.xxx.rds.amazonaws.com', 3306, 500, 100),   -- Slave (AZ-b)
  (20, 'rds2.xxx.rds.amazonaws.com', 3306, 100, 100);   -- Warm Standby (AZ-d)

-- 쿼리 라우팅 규칙
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup)
VALUES
  (1, 1, '^SELECT.*FOR UPDATE', 10),  -- SELECT FOR UPDATE → Master
  (2, 1, '^SELECT', 20),               -- SELECT → Slave
  (3, 1, '.*', 10);                     -- 나머지 → Master
```

**인터페이스:**
```
ProxySQL 관리 인터페이스:
- 포트: 6032 (관리용)
- 포트: 6033 (WAS용 MySQL 프로토콜)

REST API (ProxySQL Cluster 통해):
- GET /stats/mysql_connection_pool
- POST /runtime/mysql_servers
```

### 2. Failover Controller (Lambda)

Failover/Rollback 로직을 실행하는 Lambda 함수입니다.

```python
# failover_controller.py - 핵심 인터페이스

class FailoverController:
    def __init__(self, config: FailoverConfig):
        self.state_manager = DynamoDBStateManager(config.state_table)
        self.proxysql_client = ProxySQLClient(config.proxysql_endpoint)
        self.rds_client = boto3.client('rds')
        self.sns_client = boto3.client('sns')
    
    def handle_event(self, event: CloudWatchEvent) -> FailoverResult:
        """CloudWatch 알람 이벤트 처리"""
        pass
    
    def execute_failover(self, from_db: str, to_db: str) -> FailoverResult:
        """Failover 실행"""
        pass
    
    def execute_rollback(self, to_master: str) -> RollbackResult:
        """Rollback 실행"""
        pass
    
    def update_proxysql_routing(self, new_master: str) -> bool:
        """ProxySQL 라우팅 업데이트"""
        pass

# 상태 정의
class DBState(Enum):
    MASTER = "master"
    SLAVE = "slave"
    STANDBY = "standby"
    FAILED = "failed"
    RECOVERING = "recovering"

class SystemState:
    ec2_db1: DBState
    rds1: DBState
    rds2: DBState
    current_master: str
    last_failover: datetime
    last_rollback: datetime
```

### 3. Health Monitor (CloudWatch)

DB 상태를 모니터링하고 알람을 발생시킵니다.

```python
# health_monitor.py - Lambda 함수

class HealthMonitor:
    def __init__(self, config: MonitorConfig):
        self.cloudwatch = boto3.client('cloudwatch')
        self.db_endpoints = config.db_endpoints
    
    def check_db_health(self, endpoint: str) -> HealthStatus:
        """DB 연결 및 상태 확인"""
        pass
    
    def check_replication_lag(self, slave_endpoint: str) -> int:
        """복제 지연 시간 확인 (초)"""
        pass
    
    def publish_metrics(self, metrics: List[Metric]) -> None:
        """CloudWatch 메트릭 발행"""
        pass

class HealthStatus:
    is_healthy: bool
    latency_ms: int
    replication_lag_seconds: int
    error_message: Optional[str]
```

### 4. Replication Manager

MySQL 복제 설정 및 재구성을 담당합니다.

```python
# replication_manager.py

class ReplicationManager:
    def __init__(self, config: ReplicationConfig):
        self.mysql_connections = {}
    
    def setup_master(self, endpoint: str) -> bool:
        """Master DB 설정 (바이너리 로그 활성화)"""
        pass
    
    def setup_slave(self, slave: str, master: str) -> bool:
        """Slave 복제 설정"""
        pass
    
    def stop_replication(self, slave: str) -> bool:
        """복제 중지"""
        pass
    
    def promote_to_master(self, slave: str) -> bool:
        """Slave를 Master로 승격"""
        pass
    
    def reconfigure_replication_chain(self, new_master: str) -> bool:
        """복제 체인 재구성"""
        pass
    
    def sync_from_master(self, target: str, master: str) -> bool:
        """Master로부터 데이터 동기화"""
        pass
```

### 5. State Manager (DynamoDB)

시스템 상태를 저장하고 관리합니다.

```python
# state_manager.py

class DynamoDBStateManager:
    def __init__(self, table_name: str):
        self.dynamodb = boto3.resource('dynamodb')
        self.table = self.dynamodb.Table(table_name)
    
    def get_current_state(self) -> SystemState:
        """현재 시스템 상태 조회"""
        pass
    
    def update_state(self, new_state: SystemState) -> bool:
        """상태 업데이트 (조건부 쓰기로 동시성 제어)"""
        pass
    
    def acquire_lock(self, operation: str) -> bool:
        """작업 락 획득"""
        pass
    
    def release_lock(self, operation: str) -> bool:
        """작업 락 해제"""
        pass
```

## 데이터 모델

### SystemState (DynamoDB)

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

### FailoverEvent (DynamoDB)

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

### ProxySQL 서버 설정

```json
{
  "hostgroup_id": 10,
  "hostname": "ec2-db1.internal",
  "port": 3306,
  "status": "ONLINE|OFFLINE|SHUNNED",
  "weight": 1000,
  "max_connections": 100,
  "max_replication_lag": 10
}
```

### CloudWatch 메트릭 스키마

```json
{
  "namespace": "DBMigration/Failover",
  "metrics": [
    {
      "name": "DBHealthStatus",
      "dimensions": [{"Name": "DBInstance", "Value": "ec2_db1|rds1|rds2"}],
      "value": 1,
      "unit": "Count"
    },
    {
      "name": "ReplicationLag",
      "dimensions": [{"Name": "SlaveInstance", "Value": "rds1|rds2"}],
      "value": 0,
      "unit": "Seconds"
    },
    {
      "name": "QueryLatency",
      "dimensions": [{"Name": "DBInstance", "Value": "ec2_db1|rds1|rds2"}],
      "value": 5,
      "unit": "Milliseconds"
    }
  ]
}
```

## 정확성 속성

*속성(Property)은 시스템의 모든 유효한 실행에서 참이어야 하는 특성 또는 동작입니다. 속성은 사람이 읽을 수 있는 명세와 기계가 검증할 수 있는 정확성 보장 사이의 다리 역할을 합니다.*

### 속성 1: 쓰기 쿼리 Master 라우팅

*모든* 쓰기 쿼리(INSERT, UPDATE, DELETE, SELECT FOR UPDATE)에 대해, ProxySQL은 쿼리 내용이나 타이밍에 관계없이 현재 Master 데이터베이스로 라우팅해야 한다.

**검증 대상: 요구사항 1.1**

### 속성 2: 읽기 쿼리 Slave 라우팅

*모든* 읽기 전용 SELECT 쿼리(SELECT FOR UPDATE 제외)에 대해, ProxySQL은 라우팅 풀에서 사용 가능한 Slave 데이터베이스로 라우팅해야 한다.

**검증 대상: 요구사항 1.2**

### 속성 3: 연속 헬스체크 실패 시 Failover 시작

Failover 체인의 *모든* 데이터베이스(EC2_DB1 또는 RDS1)에 대해, 헬스체크가 3회 연속 실패하면 Failover_Controller는 체인의 다음 데이터베이스로 Failover를 시작해야 한다.

**검증 대상: 요구사항 3.1, 4.1**

### 속성 4: Master 변경 시 복제 체인 재구성

*모든* Master 승격 이벤트에 대해, Replication_Manager는 Failover 프로세스 내에서 모든 하위 데이터베이스가 새 Master로부터 복제하도록 재구성해야 한다.

**검증 대상: 요구사항 2.5, 3.5, 5.5**

### 속성 5: EC2 DB1 복구 시 롤백 시작

*모든* EC2_DB1 복구 이벤트(실패 후 헬스체크 성공)에 대해, Failover_Controller는 EC2_DB1을 Master로 복원하기 위한 롤백 프로세스를 시작해야 한다.

**검증 대상: 요구사항 5.2**

### 속성 6: 데이터베이스 접근 불가 시 CloudWatch 알람 발행

접근 불가능해진 *모든* 데이터베이스에 대해, Health_Monitor는 다음 헬스체크 주기 내에 CloudWatch 알람을 발행해야 한다.

**검증 대상: 요구사항 6.5**

### 속성 7: 상태 기반 액션 결정

*모든* 시스템 상태 조합(EC2_DB1 상태, RDS1 상태, RDS2 상태, current_master)에 대해, Failover_Controller는 정확히 하나의 적절한 액션(failover, rollback, 또는 no-op)을 결정해야 한다.

**검증 대상: 요구사항 7.2**

### 속성 8: Failover 작업 멱등성

*모든* failover 또는 rollback 작업에 대해, 동일한 입력 상태로 여러 번 실행해도 동일한 최종 상태를 생성하고 중복 부작용을 발생시키지 않아야 한다.

**검증 대상: 요구사항 7.4**

### 속성 9: WAS 연결 실패 우아한 처리

*모든* 일시적인 데이터베이스 연결 실패에 대해, WAS_Application은 크래시 없이 우아하게 처리하고 설정된 정책에 따라 연결을 재시도해야 한다.

**검증 대상: 요구사항 8.4**

## 에러 처리

### 데이터베이스 연결 에러

| 에러 유형 | 감지 방법 | 대응 |
|----------|----------|------|
| 연결 타임아웃 | 5초 타임아웃 | 재시도 후 헬스체크 실패 카운트 증가 |
| 인증 실패 | MySQL 에러 코드 | 알람 발생, 수동 개입 필요 |
| 네트워크 접근 불가 | Socket 에러 | 헬스체크 실패 카운트 증가 |

### Failover 프로세스 에러

| 에러 유형 | 감지 방법 | 대응 |
|----------|----------|------|
| 복제 중지 실패 | MySQL 에러 | 재시도 3회, 실패 시 알람 |
| ProxySQL 업데이트 실패 | Admin API 에러 | 재시도 3회, 실패 시 수동 개입 |
| 상태 업데이트 충돌 | DynamoDB 조건부 쓰기 실패 | 상태 재조회 후 재시도 |
| 락 획득 실패 | DynamoDB 락 충돌 | 대기 후 재시도 |

### Rollback 프로세스 에러

| 에러 유형 | 감지 방법 | 대응 |
|----------|----------|------|
| 데이터 동기화 실패 | 복제 에러 | 알람 발생, 롤백 중단 |
| 동기화 타임아웃 | 5분 초과 | 알람 발생, 수동 개입 필요 |

### 에러 복구 전략

```python
class ErrorHandler:
    MAX_RETRIES = 3
    RETRY_DELAY_SECONDS = 5
    
    def handle_with_retry(self, operation: Callable, error_type: str) -> Result:
        for attempt in range(self.MAX_RETRIES):
            try:
                return operation()
            except Exception as e:
                self.log_error(error_type, attempt, e)
                if attempt < self.MAX_RETRIES - 1:
                    time.sleep(self.RETRY_DELAY_SECONDS * (attempt + 1))
        
        self.send_alert(error_type, "최대 재시도 횟수 초과")
        raise FailoverError(f"{error_type} {self.MAX_RETRIES}회 시도 후 실패")
```

## 테스트 전략

### 단위 테스트

단위 테스트는 개별 컴포넌트의 로직을 검증합니다.

- **FailoverController**: 상태 전이 로직, 액션 결정 로직
- **ReplicationManager**: 복제 명령 생성, 상태 파싱
- **HealthMonitor**: 헬스체크 로직, 메트릭 계산
- **StateManager**: 상태 직렬화/역직렬화, 락 로직

### 속성 기반 테스트

속성 기반 테스트는 pytest + Hypothesis를 사용하여 구현합니다.

**테스트 설정:**
- 최소 100회 반복 실행
- 각 테스트는 설계 문서의 속성 번호 참조
- 태그 형식: `Feature: db-cloud-migration-failover, Property N: {property_text}`

**테스트 대상 속성:**
1. 속성 1: 쓰기 쿼리 Master 라우팅
2. 속성 2: 읽기 쿼리 Slave 라우팅
3. 속성 3: 연속 헬스체크 실패 시 Failover
4. 속성 4: Master 변경 시 복제 체인 재구성
5. 속성 5: EC2 DB1 복구 시 롤백
6. 속성 6: DB 장애 시 CloudWatch 알람
7. 속성 7: 상태 기반 액션 결정
8. 속성 8: Failover 멱등성
9. 속성 9: WAS 연결 실패 우아한 처리

### 통합 테스트

통합 테스트는 LocalStack 또는 실제 AWS 환경에서 실행합니다.

- **End-to-End Failover**: EC2 DB1 장애 → RDS1 승격 → 라우팅 변경
- **End-to-End Rollback**: EC2 DB1 복구 → 동기화 → Master 복귀
- **Cascading Failover**: EC2 DB1 + RDS1 장애 → RDS2 승격

### 테스트 환경

```yaml
# docker-compose.test.yml
services:
  mysql-master:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: test
    ports:
      - "3306:3306"
  
  mysql-slave1:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: test
    ports:
      - "3307:3306"
  
  mysql-slave2:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: test
    ports:
      - "3308:3306"
  
  proxysql:
    image: proxysql/proxysql:2.5.5
    ports:
      - "6033:6033"
      - "6032:6032"
  
  localstack:
    image: localstack/localstack
    ports:
      - "4566:4566"
    environment:
      SERVICES: dynamodb,cloudwatch,sns,lambda
```
