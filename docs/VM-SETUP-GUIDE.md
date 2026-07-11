# VM 설정 가이드

VM Workstation에서 Ubuntu 24.04 기반 4개 VM을 설정하는 상세 가이드입니다.

## 공통 설정 (모든 VM)

### 1. Ubuntu 24.04 설치

1. VM Workstation에서 새 VM 생성
2. Ubuntu 24.04 Server ISO 마운트
3. 기본 설정으로 설치
   - 사용자: ubuntu
   - 호스트명: web1, was1, proxysql1, db1
   - 최소 설치 선택

### 2. 네트워크 설정 (DHCP)

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

다음과 같이 수정:
```yaml
network:
  version: 2
  ethernets:
    ens33:  # 인터페이스 이름 확인 (ip a)
      dhcp4: true
```

적용:
```bash
sudo netplan apply
```

### 3. 기본 패키지 설치

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl wget vim net-tools
```

### 4. SSM Agent 설치 (AWS Session Manager 접속용)

```bash
curl -o /tmp/amazon-ssm-agent.deb https://s3.ap-northeast-2.amazonaws.com/amazon-ssm-ap-northeast-2/latest/debian_amd64/amazon-ssm-agent.deb
sudo dpkg -i /tmp/amazon-ssm-agent.deb
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent
```

**참고**: SSM Agent는 AWS로 마이그레이션 후 Session Manager를 통한 안전한 SSH 접속을 위해 필요합니다.

## VM 1: Web (Nginx)

### 설치

```bash
sudo apt install -y nginx
```

### 설정

```bash
sudo nano /etc/nginx/sites-available/default
```

다음 내용으로 교체:
```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://<WAS_IP>:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

**주의**: `<WAS_IP>`는 나중에 AWS에서 WAS의 Private IP로 교체합니다.

### 서비스 활성화

```bash
sudo systemctl enable nginx
sudo systemctl start nginx
```

### 테스트

```bash
curl http://localhost
```

## VM 2: WAS (Flask)

### Python 및 Flask 설치

```bash
sudo apt install -y python3 python3-pip python3-venv python3-flask python3-pymysql
pip3 install DBUtils --break-system-packages
```

**참고**: Ubuntu 24.04는 시스템 Python 환경 보호를 위해 `pip3 install`을 직접 사용할 수 없습니다. 시스템 패키지(`python3-flask`, `python3-pymysql`)를 사용하고, `DBUtils`는 `--break-system-packages` 플래그로 설치합니다.

### Flask 애플리케이션 설정

```bash
mkdir -p /home/ubuntu/app
cd /home/ubuntu/app
```

`app.py` 파일 생성:
```python
from flask import Flask, render_template_string
import pymysql
from pymysql import cursors
from dbutils.pooled_db import PooledDB
import socket

app = Flask(__name__)

# 로컬 테스트: MySQL 직접 연결 (ProxySQL 없이)
# AWS 배포 후: <MYSQL_IP>를 ProxySQL IP로 변경하고 port를 6033으로 변경
pool = PooledDB(
    creator=pymysql,
    maxconnections=5,
    host="<MYSQL_IP>",  # 로컬: MySQL VM IP, AWS: ProxySQL/NLB IP
    port=3306,           # 로컬: 3306, AWS: 6033 (ProxySQL)
    user="was_user",
    password="test1234",
    database="toydb",
    cursorclass=cursors.DictCursor
)

@app.route('/')
def index():
    try:
        conn = pool.connection()
        cursor = conn.cursor()
        
        cursor.execute("SELECT @@hostname AS db_host, NOW() as now")
        result = cursor.fetchone()
        
        cursor.close()
        conn.close()

        return render_template_string('''
            <h1>DB Migration Failover Test</h1>
            <p><strong>WAS Host:</strong> {{ was_host }}</p>
            <p><strong>Connected DB Host:</strong> {{ db_host }}</p>
            <p><strong>Current Time:</strong> {{ now }}</p>
        ''', was_host=socket.gethostname(), db_host=result['db_host'], now=result['now'])
    except Exception as e:
        return f"<h1>Error</h1><p>{str(e)}</p>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
```

**주의**: 
- 로컬 테스트 시: `<MYSQL_IP>`를 MySQL VM의 IP로 변경, port는 3306
- AWS 배포 후: `<MYSQL_IP>`를 ProxySQL 또는 NLB IP로 변경, port는 6033

### Systemd 서비스 생성

```bash
sudo nano /etc/systemd/system/flask-app.service
```

내용:
```ini
[Unit]
Description=Flask WAS Application
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/app
ExecStart=/usr/bin/python3 /home/ubuntu/app/app.py
Restart=always

[Install]
WantedBy=multi-user.target
```

### 서비스 활성화

```bash
sudo systemctl daemon-reload
sudo systemctl enable flask-app
sudo systemctl start flask-app
```

### 테스트

```bash
curl http://localhost:5000
```

## VM 3: ProxySQL

### ProxySQL 설치

```bash
sudo apt update
sudo apt upgrade -y
cd /tmp
wget https://github.com/sysown/proxysql/releases/download/v3.0.3/proxysql_3.0.3-ubuntu24_amd64.deb
sudo dpkg -i proxysql_3.0.3-ubuntu24_amd64.deb
```

### 서비스 활성화

```bash
sudo systemctl enable proxysql
sudo systemctl start proxysql
```

### 관리자 접속 테스트

```bash
mysql -u admin -padmin -h 127.0.0.1 -P6032
```

ProxySQL 설정은 AWS 배포 후 스크립트로 진행합니다.

## VM 4: MySQL (DB1)

### MySQL 설치

```bash
sudo apt install -y mysql-server
```

### MySQL 보안 설정

```bash
sudo mysql_secure_installation
```

**설정 가이드**:
- VALIDATE PASSWORD component? → N (테스트 환경이므로 간단한 비밀번호 허용)
- Remove anonymous users? → Y
- Disallow root login remotely? → Y
- Remove test database? → Y
- Reload privilege tables? → Y

**참고**: Ubuntu 24.04 MySQL은 root 계정이 `auth_socket`으로 보호되어 있어 `sudo mysql`로 접속 가능합니다.

### GTID 및 바이너리 로그 설정

```bash
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
```

다음 내용 추가:
```ini
[mysqld]
server-id = 1
log_bin = /var/log/mysql/mysql-bin.log
binlog-format = ROW
gtid-mode = ON
enforce-gtid-consistency = ON
log-slave-updates = ON
```

### MySQL 재시작

```bash
sudo systemctl restart mysql
```

### 복제 및 애플리케이션 사용자 생성

```bash
sudo mysql
```

MySQL 콘솔에서:
```sql
-- 복제 전용 사용자 (AWS DMS/RDS가 데이터 복제 시 사용)
CREATE USER 'toypj'@'%' IDENTIFIED BY 'test123';
GRANT REPLICATION SLAVE ON *.* TO 'toypj'@'%';

-- 애플리케이션 사용자 (Flask WAS가 데이터 읽기/쓰기 시 사용)
CREATE USER 'was_user'@'%' IDENTIFIED BY 'test1234';
GRANT ALL PRIVILEGES ON toydb.* TO 'was_user'@'%';

-- 테스트 데이터베이스 및 테이블 생성
CREATE DATABASE toydb;
USE toydb;
CREATE TABLE test (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100));
INSERT INTO test (name) VALUES ('Initial Data');

FLUSH PRIVILEGES;
EXIT;
```

**사용자 역할**:
- `toypj`: 복제 전용 (최소 권한 - 바이너리 로그 읽기만 가능)
- `was_user`: 애플리케이션 전용 (toydb 데이터베이스 전체 권한)

### 서비스 활성화

```bash
sudo systemctl enable mysql
```

## VM 내보내기 준비

모든 VM 설정 완료 후:

### 1. CloudWatch Agent 설치 (모든 VM)

```bash
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb
```

**참고**: CloudWatch Agent는 AWS로 마이그레이션 후 로그 및 메트릭 수집을 위해 필요합니다.

### 2. MySQL 복제 권한 추가 (DB VM만)

```bash
sudo mysql
```

MySQL 콘솔에서:
```sql
-- DMS가 바이너리 로그를 읽을 수 있도록 추가 권한 부여
GRANT REPLICATION CLIENT ON *.* TO 'toypj'@'%';
GRANT SELECT ON *.* TO 'toypj'@'%';
FLUSH PRIVILEGES;
EXIT;
```

### 3. 각 VM 정리

```bash
# 불필요한 패키지 정리 (OVA 크기 감소)
sudo apt autoremove -y
sudo apt clean

# 로그 정리
sudo journalctl --vacuum-time=1d

# machine-id 초기화 (필수 - 각 EC2가 고유 ID를 가지도록)
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup

# 히스토리 삭제 (보안)
history -c
rm ~/.bash_history

# 시스템 종료
sudo shutdown -h now
# 또는: sudo init 0
# 또는: sudo poweroff
```

**machine-id 초기화 이유**:
- VM 복제 시 모든 VM이 동일한 machine-id를 가지게 됨
- AWS에서 각 EC2 인스턴스가 고유한 ID를 가져야 네트워크/로그가 정상 작동
- 초기화하면 AWS 부팅 시 자동으로 새 ID 생성

### 2. VM Workstation에서 OVA 내보내기

1. VM 선택
2. File → Export to OVF/OVA
3. OVA 형식 선택
4. 저장 위치: `/path/to/export/`
5. 파일명: `web.ova`, `was.ova`, `proxysql.ova`, `db.ova`

**참고**: 각 VM을 개별적으로 내보내기하여 4개의 OVA 파일을 생성합니다.

## AWS 마이그레이션 준비 체크리스트

- [ ] Web VM: Nginx 설치 및 설정 완료
- [ ] WAS VM: Flask 설치 및 회원 관리 기능 테스트 완료
- [ ] ProxySQL VM: ProxySQL 설치 완료
- [ ] DB VM: MySQL 설치, GTID 설정, 복제 사용자 및 권한 설정 완료
- [ ] 모든 VM: 네트워크 DHCP 설정 완료
- [ ] 모든 VM: SSM Agent 설치 완료
- [ ] 모든 VM: CloudWatch Agent 설치 완료
- [ ] 모든 VM: machine-id 초기화 완료
- [ ] 모든 VM: OVA 파일 내보내기 완료

## 다음 단계

VM 준비가 완료되면:
1. `scripts/vm-import.sh` 스크립트로 AWS에 Import
2. Terraform으로 인프라 구축
3. MySQL 복제 및 ProxySQL 설정
