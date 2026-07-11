# 요구사항 문서

## 소개

온프레미스 환경에서 클라우드로의 점진적 DB 마이그레이션을 위한 고가용성 Failover 시스템입니다. EC2 DB1(Master) → RDS1(Slave) → RDS2(Warm Standby) 체인 구조로 구성되며, ProxySQL을 통한 자동 라우팅과 CloudWatch/Lambda 기반 자동 Failover/Rollback을 구현합니다.

**인프라 배치:**
- AZ-a (온프레미스 가정): Web1, WAS1, DB1 (EC2 MySQL)
- AZ-b (클라우드 마이그레이션용): Web2, WAS2, RDS1
- AZ-d (Warm Standby): RDS2

**점진적 전환 전략:**
- 1단계: 온프레미스 가정(AZ-a)에서 운영, RDS1/RDS2는 복제 대기
- 2단계: DB1 장애 시 RDS1로 Failover (클라우드 전환)
- 3단계: RDS1 장애 시 RDS2로 Failover (이중 장애 대응)

## 용어 정의

- **EC2_DB1**: AZ-a의 EC2 인스턴스에서 실행되는 MySQL 데이터베이스 (온프레미스 가정, 초기 Master)
- **RDS1**: AZ-b의 RDS MySQL 인스턴스 (클라우드 마이그레이션용, Slave → Failover 시 Master)
- **RDS2**: AZ-d의 RDS MySQL 인스턴스 (Warm Standby, DMS 동기화)
- **ProxySQL**: MySQL 프록시 레이어로 WAS와 DB 사이에서 라우팅 담당
- **Failover_Controller**: Lambda 함수로 Failover/Rollback 로직 실행
- **Health_Monitor**: CloudWatch 기반 DB 상태 모니터링 시스템
- **Replication_Manager**: MySQL 복제 설정 및 관리 컴포넌트
- **DMS**: AWS Database Migration Service (RDS2 동기화용)

## 요구사항

### 요구사항 1: ProxySQL 기반 DB 라우팅

**사용자 스토리:** WAS 개발자로서, DB 연결 정보 변경 없이 자동으로 활성 Master DB에 연결되기를 원합니다.

#### 인수 조건

1. THE ProxySQL SHALL 모든 쓰기 쿼리를 현재 Master 데이터베이스로 라우팅한다
2. THE ProxySQL SHALL 읽기 쿼리를 사용 가능한 Slave 데이터베이스로 라우팅하여 부하를 분산한다
3. WHEN Master 데이터베이스가 변경되면, THE ProxySQL SHALL 5초 이내에 라우팅 규칙을 자동 업데이트한다
4. THE ProxySQL SHALL 각 백엔드 데이터베이스에 대한 커넥션 풀을 유지한다
5. WHEN 백엔드 데이터베이스가 사용 불가능해지면, THE ProxySQL SHALL 해당 DB를 라우팅 풀에서 제거한다
6. THE ProxySQL SHALL 모니터링을 위한 헬스체크 엔드포인트를 제공한다

### 요구사항 2: MySQL 복제 구성

**사용자 스토리:** 시스템 관리자로서, EC2 DB1에서 RDS1으로의 실시간 복제가 유지되어 데이터 손실 없이 Failover할 수 있기를 원합니다.

#### 인수 조건

1. THE Replication_Manager SHALL EC2_DB1을 바이너리 로깅이 활성화된 Master로 설정한다
2. THE Replication_Manager SHALL RDS1을 EC2_DB1로부터 복제하는 Slave로 설정한다
3. WHEN 복제 지연이 10초를 초과하면, THE Health_Monitor SHALL 알람을 발생시킨다
4. THE Replication_Manager SHALL 일관성을 위해 GTID 기반 복제를 지원한다
5. WHEN RDS1이 Master가 되면, THE Replication_Manager SHALL RDS2가 RDS1로부터 복제하도록 재구성한다
6. THE Replication_Manager SHALL 30초마다 복제 상태를 검증한다

### 요구사항 3: EC2 DB1 → RDS1 Failover

**사용자 스토리:** 시스템 관리자로서, EC2 DB1 장애 시 자동으로 RDS1이 Master로 승격되어 서비스 중단을 최소화하고 싶습니다.

#### 인수 조건

1. WHEN EC2_DB1 헬스체크가 3회 연속 실패하면, THE Failover_Controller SHALL RDS1로의 Failover를 시작한다
2. WHEN Failover가 시작되면, THE Failover_Controller SHALL RDS1의 복제를 중지한다
3. WHEN Failover가 시작되면, THE Failover_Controller SHALL RDS1을 Master 역할로 승격한다
4. WHEN RDS1이 승격되면, THE Failover_Controller SHALL ProxySQL 라우팅을 RDS1으로 업데이트한다
5. WHEN RDS1이 Master가 되면, THE Replication_Manager SHALL RDS2가 RDS1로부터 복제하도록 재구성한다
6. THE Failover_Controller SHALL 60초 이내에 Failover 프로세스를 완료한다
7. WHEN Failover가 완료되면, THE Failover_Controller SHALL SNS를 통해 알림을 전송한다

### 요구사항 4: RDS1 → RDS2 Failover

**사용자 스토리:** 시스템 관리자로서, RDS1 장애 시 RDS2가 자동으로 Master로 승격되어 이중 장애에도 서비스가 유지되기를 원합니다.

#### 인수 조건

1. WHEN RDS1 헬스체크가 3회 연속 실패하면, THE Failover_Controller SHALL RDS2로의 Failover를 시작한다
2. WHEN RDS2로의 Failover가 시작되면, THE Failover_Controller SHALL DMS 복제 태스크를 중지한다
3. WHEN RDS2로의 Failover가 시작되면, THE Failover_Controller SHALL RDS2를 Master 역할로 승격한다
4. WHEN RDS2가 승격되면, THE Failover_Controller SHALL ProxySQL 라우팅을 RDS2로 업데이트한다
5. THE Failover_Controller SHALL 60초 이내에 RDS1에서 RDS2로의 Failover를 완료한다
6. WHEN Failover가 완료되면, THE Failover_Controller SHALL SNS를 통해 알림을 전송한다

### 요구사항 5: EC2 DB1 복구 시 롤백

**사용자 스토리:** 시스템 관리자로서, EC2 DB1이 복구되면 자동으로 Master 역할을 되찾아 원래 아키텍처로 복원하고 싶습니다.

#### 인수 조건

1. WHEN EC2_DB1이 다시 정상 상태가 되면, THE Health_Monitor SHALL 60초 이내에 복구를 감지한다
2. WHEN EC2_DB1 복구가 감지되면, THE Failover_Controller SHALL 롤백 프로세스를 시작한다
3. WHEN 롤백이 시작되면, THE Replication_Manager SHALL 현재 Master로부터 EC2_DB1을 동기화한다
4. WHEN EC2_DB1 데이터가 동기화되면, THE Failover_Controller SHALL EC2_DB1을 Master로 승격한다
5. WHEN EC2_DB1이 Master가 되면, THE Replication_Manager SHALL RDS1을 Slave로 재구성한다
6. WHEN 롤백이 완료되면, THE Failover_Controller SHALL ProxySQL 라우팅을 EC2_DB1으로 업데이트한다
7. THE Failover_Controller SHALL 5분 이내에 롤백을 완료한다
8. WHEN 롤백이 완료되면, THE Failover_Controller SHALL SNS를 통해 알림을 전송한다

### 요구사항 6: CloudWatch 모니터링

**사용자 스토리:** 운영자로서, 모든 DB 인스턴스의 상태를 실시간으로 모니터링하여 장애를 빠르게 감지하고 싶습니다.

#### 인수 조건

1. THE Health_Monitor SHALL 10초마다 EC2_DB1 연결 상태를 확인한다
2. THE Health_Monitor SHALL 10초마다 RDS1 연결 상태를 확인한다
3. THE Health_Monitor SHALL 10초마다 RDS2 연결 상태를 확인한다
4. THE Health_Monitor SHALL 모든 Slave 데이터베이스의 복제 지연을 모니터링한다
5. WHEN 어떤 데이터베이스든 접근 불가능해지면, THE Health_Monitor SHALL CloudWatch 알람을 발행한다
6. THE Health_Monitor SHALL 쿼리 지연 시간 메트릭을 추적하고 발행한다
7. THE Health_Monitor SHALL 모든 DB 상태를 보여주는 대시보드를 유지한다

### 요구사항 7: Lambda 자동화

**사용자 스토리:** 시스템 관리자로서, Failover와 Rollback이 자동으로 실행되어 수동 개입 없이 시스템이 복구되기를 원합니다.

#### 인수 조건

1. WHEN CloudWatch 알람이 트리거되면, THE Failover_Controller Lambda SHALL 자동으로 호출된다
2. THE Failover_Controller SHALL 현재 상태를 기반으로 적절한 액션을 결정한다
3. THE Failover_Controller SHALL 일관성을 위해 DynamoDB에 상태를 유지한다
4. THE Failover_Controller SHALL 중복 액션을 방지하기 위해 멱등성 있는 작업을 구현한다
5. IF Failover_Controller 실행이 실패하면, THEN THE Failover_Controller SHALL 최대 3회까지 재시도한다
6. THE Failover_Controller SHALL 감사를 위해 모든 액션을 CloudWatch Logs에 기록한다

### 요구사항 8: WAS 연결 구성

**사용자 스토리:** WAS 개발자로서, ProxySQL을 통해 DB에 연결하여 Failover 시에도 연결이 자동으로 유지되기를 원합니다.

#### 인수 조건

1. THE WAS_Application SHALL 직접 데이터베이스 연결 대신 ProxySQL에 연결한다
2. THE WAS_Application SHALL ProxySQL과 커넥션 풀링을 사용한다
3. WHEN 데이터베이스 연결이 실패하면, THE WAS_Application SHALL 5초 이내에 연결을 재시도한다
4. THE WAS_Application SHALL 일시적인 연결 실패를 우아하게 처리한다
5. THE ProxySQL SHALL 투명한 WAS 통합을 위해 MySQL 프로토콜을 지원한다
