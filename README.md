# DB 클라우드 마이그레이션 Failover 시스템

온프레미스 환경에서 클라우드로의 점진적 DB 마이그레이션을 위한 고가용성 Failover 시스템입니다.

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
