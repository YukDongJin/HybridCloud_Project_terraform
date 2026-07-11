# GTID 설정 가이드 (선택사항)

## 개요
현재 프로젝트는 **전통적인 MySQL 복제 방식**을 사용하며, GTID 없이도 모든 기능이 정상 작동합니다.
하지만 프로덕션 환경에서는 **GTID(Global Transaction Identifier) 사용을 권장**합니다.

---

## GTID란?

### 1. **GTID (Global Transaction Identifier)**
MySQL 복제에서 각 트랜잭션에 **고유한 글로벌 ID**를 부여하는 기능입니다.

### 2. **전통적 복제 vs GTID 복제**

#### 전통적 복제 (현재 사용 중):
```sql
CHANGE MASTER TO
  MASTER_HOST='10.0.11.151',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password123';
```
- **장점**: 간단하고 설정이 쉬움
- **단점**: 복잡한 Failover 시 바이너리 로그 위치 추적 어려움

#### GTID 복제:
```sql
CHANGE MASTER TO
  MASTER_HOST='10.0.11.151',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password123',
  MASTER_AUTO_POSITION=1;  -- GTID 자동 위치 찾기
```
- **장점**: Failover 시 자동으로 올바른 위치 찾음, 데이터 일관성 보장
- **단점**: 설정이 복잡하고 RDS 재시작 필요

### 3. **GTID가 필요한 경우**

✅ **GTID 사용 권장**:
- 프로덕션 환경
- 복잡한 복제 토폴로지 (Multi-Master, Cascading Replication)
- 빈번한 Failover/Rollback
- 데이터 일관성이 매우 중요한 경우

❌ **GTID 없이도 충분**:
- 개발/테스트 환경
- 단순한 Master-Slave 구조
- 데모/발표용 프로젝트 (현재 상황)

---

## GTID 활성화 방법

### 1. **RDS 파라미터 그룹 생성**

Terraform 코드에 추가:

```hcl
# infrastructure/terraform/modules/rds/main.tf

# RDS 파라미터 그룹 (GTID 활성화)
resource "aws_db_parameter_group" "mysql_gtid" {
  name   = "${var.project_name}-mysql-gtid-params"
  family = "mysql8.0"

  # GTID 필수 파라미터
  parameter {
    name         = "gtid_mode"
    value        = "ON"
    apply_method = "pending-reboot"  # 재시작 필요
  }

  parameter {
    name         = "enforce_gtid_consistency"
    value        = "ON"
    apply_method = "pending-reboot"
  }

  # 복제 최적화 파라미터
  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_bin_trust_function_creators"
    value        = "1"
    apply_method = "immediate"
  }

  tags = {
    Name = "${var.project_name}-mysql-gtid-params"
  }
}

# RDS1에 파라미터 그룹 적용
resource "aws_db_instance" "rds1" {
  # ... 기존 설정 ...
  parameter_group_name = aws_db_parameter_group.mysql_gtid.name
  # ... 기존 설정 ...
}

# RDS2에 파라미터 그룹 적용
resource "aws_db_instance" "rds2" {
  # ... 기존 설정 ...
  parameter_group_name = aws_db_parameter_group.mysql_gtid.name
  # ... 기존 설정 ...
}
```

### 2. **Terraform Apply**

```bash
cd infrastructure/terraform
terraform apply
```

**주의**: 파라미터 그룹 변경 시 RDS 인스턴스 재시작이 필요합니다.

### 3. **RDS 인스턴스 재시작**

#### 옵션 1: 즉시 재시작 (서비스 중단 2-3분)
```bash
# RDS1 재시작
aws rds reboot-db-instance --db-instance-identifier db-failover-rds1

# RDS2 재시작
aws rds reboot-db-instance --db-instance-identifier db-failover-rds2
```

#### 옵션 2: 유지보수 기간에 자동 재시작 (권장)
- Terraform에서 `apply_immediately = false` 설정
- 다음 유지보수 기간(월요일 04:00-05:00)에 자동 재시작
- 서비스 중단 최소화

### 4. **Lambda 코드 수정**

GTID 활성화 후 Lambda 코드에서 `MASTER_AUTO_POSITION=1` 추가:

```python
# lambda/failover_controller.py

# Rollback 시 역방향 복제 설정
success, msg = self.execute_mysql_command(
    self.db_endpoints['ec2_db1'],
    f"""
    STOP SLAVE;
    CHANGE MASTER TO
      MASTER_HOST='{self.db_endpoints['rds1']}',
      MASTER_USER='repl_user',
      MASTER_PASSWORD='{os.environ.get('REPL_PASSWORD', 'repl_password123')}',
      MASTER_AUTO_POSITION=1;  # GTID 자동 위치 찾기
    START SLAVE;
    """
)
```

### 5. **Lambda ZIP 재빌드 및 배포**

```bash
# Lambda 빌드
cd lambda
./build.sh

# Terraform apply (Lambda 업데이트)
cd ../infrastructure/terraform
terraform apply
```

### 6. **GTID 활성화 확인**

```bash
# RDS1 접속
mysql -u admin -ptest123! -h <RDS1_ENDPOINT>

# GTID 상태 확인
SHOW VARIABLES LIKE 'gtid_mode';
-- 예상 결과: ON

SHOW VARIABLES LIKE 'enforce_gtid_consistency';
-- 예상 결과: ON

# 현재 GTID 확인
SHOW MASTER STATUS;
-- Executed_Gtid_Set 필드에 GTID 표시됨

exit
```

---

## GTID 활성화 시 장점

### 1. **자동 위치 찾기**
```sql
-- GTID 없이
CHANGE MASTER TO
  MASTER_LOG_FILE='mysql-bin.000003',
  MASTER_LOG_POS=154;  -- 수동으로 위치 지정

-- GTID 사용
CHANGE MASTER TO
  MASTER_AUTO_POSITION=1;  -- 자동으로 위치 찾기
```

### 2. **Failover 시 데이터 일관성**
- Master 장애 시 Slave가 정확히 어디까지 복제했는지 추적
- 중복 트랜잭션 방지
- 누락 트랜잭션 자동 감지

### 3. **복잡한 토폴로지 지원**
```
DB1 (Master)
  ↓
RDS1 (Slave) ──→ RDS2 (Slave)
  ↓
RDS3 (Slave)
```
- 여러 Slave가 있어도 GTID로 정확한 위치 추적

### 4. **Rollback 안정성**
- 역방향 복제 시 자동으로 올바른 시작 위치 찾음
- 데이터 손실 최소화

---

## GTID 없이 현재 구조가 작동하는 이유

### 1. **단순한 토폴로지**
```
DB1 → RDS1 → RDS2
```
- 단방향 복제 체인
- 복잡한 위치 추적 불필요

### 2. **자동 위치 감지**
```sql
CHANGE MASTER TO
  MASTER_HOST='rds1.amazonaws.com',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password123';
-- 바이너리 로그 위치 지정 안하면 현재 위치부터 시작
```

### 3. **Lambda가 최신 위치 사용**
- Rollback 시 Master의 현재 위치부터 복제 시작
- 대부분의 경우 데이터 손실 없음

---

## 프로덕션 환경 권장 사항

### 1. **GTID 활성화**
- 데이터 일관성 보장
- Failover 안정성 향상

### 2. **백업 전략**
```bash
# 정기 백업 (GTID 포함)
mysqldump --all-databases --single-transaction \
  --master-data=2 --set-gtid-purged=ON \
  > backup.sql
```

### 3. **모니터링 강화**
```sql
-- GTID 복제 상태 확인
SHOW SLAVE STATUS\G
-- Retrieved_Gtid_Set: 받은 GTID
-- Executed_Gtid_Set: 실행한 GTID
```

### 4. **복제 지연 알람**
- CloudWatch Alarm 임계값 낮추기 (10초 → 5초)
- GTID 기반 복제 지연 모니터링

---

## 현재 프로젝트 상태

### ✅ **현재 구성 (GTID 없음)**:
- 전통적인 MySQL 복제 사용
- 단순하고 안정적
- 데모/발표에 충분

### 🔄 **프로덕션 전환 시 (GTID 활성화)**:
1. RDS 파라미터 그룹 생성
2. RDS 인스턴스 재시작
3. Lambda 코드 수정 (`MASTER_AUTO_POSITION=1` 추가)
4. Lambda 재배포
5. 전체 테스트

---

## 요약

| 항목 | GTID 없음 (현재) | GTID 사용 |
|------|------------------|-----------|
| **설정 난이도** | 쉬움 | 복잡 |
| **RDS 재시작** | 불필요 | 필요 (2-3분) |
| **Failover 안정성** | 보통 | 높음 |
| **데이터 일관성** | 보통 | 높음 |
| **복잡한 토폴로지** | 어려움 | 쉬움 |
| **프로덕션 권장** | ❌ | ✅ |
| **데모/발표** | ✅ | ⚠️ (시간 소요) |

---

## 결론

**현재 프로젝트**: GTID 없이도 모든 기능이 정상 작동합니다.

**프로덕션 환경**: GTID 활성화를 권장합니다.

**발표 시 언급**: "현재는 전통적인 복제 방식을 사용하지만, 프로덕션 환경에서는 GTID를 활성화하여 데이터 일관성과 Failover 안정성을 향상시킬 수 있습니다."

