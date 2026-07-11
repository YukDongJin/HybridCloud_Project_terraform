#!/bin/bash

# MySQL 복제 설정 스크립트
# EC2 DB1 (Master) → RDS1 (Slave) 복제 구성

set -e

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== MySQL Replication Setup ===${NC}"

# 환경 변수 확인
if [ -z "$EC2_DB1_IP" ] || [ -z "$RDS1_ENDPOINT" ]; then
    echo -e "${RED}Error: EC2_DB1_IP and RDS1_ENDPOINT must be set${NC}"
    echo "Usage: EC2_DB1_IP=<ip> RDS1_ENDPOINT=<endpoint> ./setup-mysql-replication.sh"
    exit 1
fi

DB_PASSWORD=${DB_PASSWORD:-"test123!"}
REPL_PASSWORD=${REPL_PASSWORD:-"repl_password123"}

echo -e "${YELLOW}EC2 DB1 (Master): ${EC2_DB1_IP}${NC}"
echo -e "${YELLOW}RDS1 (Slave): ${RDS1_ENDPOINT}${NC}"

# 1. EC2 DB1에서 복제 사용자 생성 및 상태 확인
echo -e "${YELLOW}1. Setting up EC2 DB1 as Master...${NC}"

mysql -h ${EC2_DB1_IP} -u admin -p${DB_PASSWORD} <<EOF
-- 복제 사용자 생성
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY '${REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;

-- Master 상태 확인
SHOW MASTER STATUS\G
EOF

# Master 상태 저장
MASTER_STATUS=$(mysql -h ${EC2_DB1_IP} -u admin -p${DB_PASSWORD} -e "SHOW MASTER STATUS\G")
MASTER_LOG_FILE=$(echo "$MASTER_STATUS" | grep "File:" | awk '{print $2}')
MASTER_LOG_POS=$(echo "$MASTER_STATUS" | grep "Position:" | awk '{print $2}')

echo -e "${GREEN}Master Log File: ${MASTER_LOG_FILE}${NC}"
echo -e "${GREEN}Master Log Position: ${MASTER_LOG_POS}${NC}"

# 2. RDS1을 Slave로 설정
echo -e "${YELLOW}2. Setting up RDS1 as Slave...${NC}"

mysql -h ${RDS1_ENDPOINT} -u admin -p${DB_PASSWORD} <<EOF
-- 기존 복제 중지 (있다면)
STOP SLAVE;

-- Master 설정
CHANGE MASTER TO
  MASTER_HOST='${EC2_DB1_IP}',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='${REPL_PASSWORD}',
  MASTER_LOG_FILE='${MASTER_LOG_FILE}',
  MASTER_LOG_POS=${MASTER_LOG_POS},
  MASTER_AUTO_POSITION=1;

-- 복제 시작
START SLAVE;

-- Slave 상태 확인
SHOW SLAVE STATUS\G
EOF

# 3. 복제 상태 확인
echo -e "${YELLOW}3. Verifying replication status...${NC}"

sleep 5

SLAVE_STATUS=$(mysql -h ${RDS1_ENDPOINT} -u admin -p${DB_PASSWORD} -e "SHOW SLAVE STATUS\G")
SLAVE_IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SLAVE_SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

if [ "$SLAVE_IO_RUNNING" == "Yes" ] && [ "$SLAVE_SQL_RUNNING" == "Yes" ]; then
    echo -e "${GREEN}✓ Replication is running successfully!${NC}"
else
    echo -e "${RED}✗ Replication failed!${NC}"
    echo -e "${RED}Slave_IO_Running: ${SLAVE_IO_RUNNING}${NC}"
    echo -e "${RED}Slave_SQL_Running: ${SLAVE_SQL_RUNNING}${NC}"
    exit 1
fi

# 4. 테스트 데이터 삽입
echo -e "${YELLOW}4. Testing replication with sample data...${NC}"

mysql -h ${EC2_DB1_IP} -u admin -p${DB_PASSWORD} <<EOF
USE testdb;
INSERT INTO test (name) VALUES ('Replication Test - $(date)');
SELECT * FROM test ORDER BY id DESC LIMIT 5;
EOF

echo -e "${YELLOW}Waiting 5 seconds for replication...${NC}"
sleep 5

echo -e "${YELLOW}Checking replicated data on RDS1...${NC}"
mysql -h ${RDS1_ENDPOINT} -u admin -p${DB_PASSWORD} <<EOF
USE testdb;
SELECT * FROM test ORDER BY id DESC LIMIT 5;
EOF

echo -e "${GREEN}=== Replication Setup Completed ===${NC}"
echo ""
echo "Next steps:"
echo "1. Set up DMS for RDS1 → RDS2 synchronization"
echo "2. Configure ProxySQL routing"
echo "3. Deploy Lambda functions"
