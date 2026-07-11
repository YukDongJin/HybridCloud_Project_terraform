#!/bin/bash

# ProxySQL 설정 스크립트

set -e

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== ProxySQL Setup ===${NC}"

# 환경 변수 확인
if [ -z "$PROXYSQL_IP" ] || [ -z "$EC2_DB1_IP" ] || [ -z "$RDS1_ENDPOINT" ] || [ -z "$RDS2_ENDPOINT" ]; then
    echo -e "${RED}Error: Required environment variables not set${NC}"
    echo "Usage: PROXYSQL_IP=<ip> EC2_DB1_IP=<ip> RDS1_ENDPOINT=<endpoint> RDS2_ENDPOINT=<endpoint> ./setup-proxysql.sh"
    exit 1
fi

DB_PASSWORD=${DB_PASSWORD:-"test123!"}

echo -e "${YELLOW}ProxySQL: ${PROXYSQL_IP}${NC}"
echo -e "${YELLOW}EC2 DB1: ${EC2_DB1_IP}${NC}"
echo -e "${YELLOW}RDS1: ${RDS1_ENDPOINT}${NC}"
echo -e "${YELLOW}RDS2: ${RDS2_ENDPOINT}${NC}"

# ProxySQL 관리 인터페이스 접속
echo -e "${YELLOW}Configuring ProxySQL...${NC}"

mysql -h ${PROXYSQL_IP} -P 6032 -u admin -padmin <<EOF

-- 1. MySQL 사용자 설정
DELETE FROM mysql_users;
INSERT INTO mysql_users (username, password, default_hostgroup, active)
VALUES ('apps_user', '${DB_PASSWORD}', 10, 1);
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;

-- 2. 백엔드 서버 설정
DELETE FROM mysql_servers;

-- Hostgroup 10: Writer (Master)
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
VALUES 
  (10, '${EC2_DB1_IP}', 3306, 1000, 100, 'EC2 DB1 - Master');

-- Hostgroup 20: Reader (Slave)
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight, max_connections, comment)
VALUES 
  (20, '${RDS1_ENDPOINT}', 3306, 500, 100, 'RDS1 - Slave'),
  (20, '${RDS2_ENDPOINT}', 3306, 100, 100, 'RDS2 - Standby');

LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

-- 3. 쿼리 라우팅 규칙 설정
DELETE FROM mysql_query_rules;

-- Rule 1: SELECT FOR UPDATE → Master
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
VALUES (1, 1, '^SELECT.*FOR UPDATE', 10, 1, 'SELECT FOR UPDATE to Master');

-- Rule 2: SELECT → Slave
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
VALUES (2, 1, '^SELECT', 20, 1, 'SELECT to Slave');

-- Rule 3: 나머지 (INSERT, UPDATE, DELETE) → Master
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
VALUES (3, 1, '.*', 10, 1, 'All other queries to Master');

LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;

-- 4. 모니터링 설정
UPDATE global_variables SET variable_value='2000' WHERE variable_name='mysql-monitor_connect_interval';
UPDATE global_variables SET variable_value='10000' WHERE variable_name='mysql-monitor_ping_interval';
UPDATE global_variables SET variable_value='10000' WHERE variable_name='mysql-monitor_read_only_interval';

LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;

-- 5. 설정 확인
SELECT * FROM mysql_servers;
SELECT * FROM mysql_users;
SELECT * FROM mysql_query_rules ORDER BY rule_id;

EOF

echo -e "${GREEN}ProxySQL configuration completed!${NC}"

# 6. 연결 테스트
echo -e "${YELLOW}Testing ProxySQL connection...${NC}"

mysql -h ${PROXYSQL_IP} -P 6033 -u apps_user -p${DB_PASSWORD} <<EOF
-- 쓰기 쿼리 테스트 (Master로 라우팅)
USE testdb;
INSERT INTO test (name) VALUES ('ProxySQL Test - $(date)');

-- 읽기 쿼리 테스트 (Slave로 라우팅)
SELECT * FROM test ORDER BY id DESC LIMIT 5;

-- 현재 연결 정보
SELECT @@hostname AS current_db;
EOF

echo -e "${GREEN}=== ProxySQL Setup Completed ===${NC}"
echo ""
echo "ProxySQL is now routing:"
echo "  - Write queries (INSERT, UPDATE, DELETE) → EC2 DB1 (Master)"
echo "  - Read queries (SELECT) → RDS1, RDS2 (Slaves)"
echo ""
echo "Connection string for WAS:"
echo "  Host: ${PROXYSQL_IP}"
echo "  Port: 6033"
echo "  User: apps_user"
echo "  Password: ${DB_PASSWORD}"
