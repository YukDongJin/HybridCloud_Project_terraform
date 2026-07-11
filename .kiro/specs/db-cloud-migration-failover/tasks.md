# 구현 계획: DB 클라우드 마이그레이션 Failover

## 개요

ProxySQL 기반 DB Failover 시스템을 구현합니다. EC2 DB1 → RDS1 → RDS2 체인 구조로 자동 Failover/Rollback을 지원합니다.

## 태스크

- [ ] 0. VM 마이그레이션 준비 (온프레미스 가정 환경)
  - [ ] 0.1 VM Workstation 네트워크 설정 변경
    - DHCP 활성화 (`/etc/netplan/*.yaml`)
    - 고정 IP 제거
    - `sudo netplan apply` 실행
    - _요구사항: 마이그레이션 전제조건_
  
  - [ ] 0.2 VM OVF/OVA 내보내기 가이드 작성
    - VM Workstation에서 OVF 내보내기 절차
    - 필요한 파일 목록 (vmdk, ovf, mf)
    - _요구사항: 마이그레이션 전제조건_
  
  - [ ] 0.3 S3 업로드 및 VM Import 스크립트 작성
    - S3 버킷 생성 및 업로드
    - VM Import/Export IAM 역할 설정
    - `aws ec2 import-image` 명령 스크립트
    - AMI 생성 확인
    - _요구사항: 마이그레이션 전제조건_

- [ ] 1. 프로젝트 구조 및 인프라 기반 설정
  - [ ] 1.1 프로젝트 디렉토리 구조 생성
    - `infrastructure/`: Terraform/CloudFormation 코드
    - `lambda/`: Lambda 함수 코드
    - `scripts/`: 설정 스크립트
    - `tests/`: 테스트 코드
    - _요구사항: 전체_
  
  - [ ] 1.2 AWS 인프라 IaC 코드 작성 (Terraform)
    - VPC, 서브넷 (AZ-a, AZ-b, AZ-d)
    - EC2 인스턴스 (DB1, ProxySQL-1, ProxySQL-2)
    - RDS 인스턴스 (RDS1, RDS2)
    - NLB 설정
    - DynamoDB 테이블
    - _요구사항: 전체 인프라_
  
  - [ ] 1.3 CloudWatch Agent 설치 스크립트 작성
    - EC2 인스턴스 (DB1, ProxySQL-1, ProxySQL-2)에 설치
    - CPU, 메모리, 디스크 메트릭 수집
    - 시스템 로그 수집 설정
    - _요구사항: 6.1, 6.2, 6.3_

- [ ] 2. MySQL 복제 구성
  - [ ] 2.1 EC2 DB1 Master 설정 스크립트 작성
    - 바이너리 로깅 활성화
    - GTID 모드 설정
    - 복제 사용자 생성
    - _요구사항: 2.1, 2.4_
  
  - [ ] 2.2 RDS1 Slave 복제 설정 스크립트 작성
    - EC2 DB1로부터 복제 설정
    - GTID 기반 복제 구성
    - _요구사항: 2.2, 2.4_
  
  - [ ] 2.3 DMS 태스크 설정 (RDS2 동기화)
    - DMS 복제 인스턴스 생성
    - RDS1 → RDS2 동기화 태스크
    - _요구사항: 2.5_

- [ ] 3. ProxySQL 설정
  - [ ] 3.1 ProxySQL 설치 및 기본 설정 스크립트 작성
    - ProxySQL 설치 (Ubuntu 24.04)
    - 관리자 계정 설정
    - MySQL 사용자 설정
    - _요구사항: 1.4, 1.6_
  
  - [ ] 3.2 백엔드 서버 및 라우팅 규칙 설정
    - mysql_servers 테이블 설정 (EC2 DB1, RDS1, RDS2)
    - mysql_query_rules 테이블 설정 (읽기/쓰기 분리)
    - hostgroup 설정 (Writer: 10, Reader: 20)
    - _요구사항: 1.1, 1.2_
  
  - [ ]* 3.3 속성 테스트: 쓰기 쿼리 Master 라우팅
    - **속성 1: 쓰기 쿼리 Master 라우팅**
    - **검증 대상: 요구사항 1.1**
  
  - [ ]* 3.4 속성 테스트: 읽기 쿼리 Slave 라우팅
    - **속성 2: 읽기 쿼리 Slave 라우팅**
    - **검증 대상: 요구사항 1.2**

- [ ] 4. 체크포인트 - ProxySQL 및 복제 설정 검증
  - 모든 테스트 통과 확인, 문제 발생 시 사용자에게 질문

- [ ] 5. Health Monitor Lambda 구현
  - [ ] 5.1 HealthMonitor 클래스 구현
    - DB 연결 상태 확인 로직
    - 복제 지연 확인 로직
    - CloudWatch 메트릭 발행
    - _요구사항: 6.1, 6.2, 6.3, 6.4, 6.6_
  
  - [ ] 5.2 CloudWatch 알람 설정
    - DB 헬스체크 실패 알람
    - 복제 지연 알람 (10초 초과)
    - _요구사항: 6.5, 2.3_
  
  - [ ]* 5.3 속성 테스트: DB 장애 시 CloudWatch 알람 발행
    - **속성 6: 데이터베이스 접근 불가 시 CloudWatch 알람 발행**
    - **검증 대상: 요구사항 6.5**

- [ ] 6. State Manager 구현
  - [ ] 6.1 DynamoDBStateManager 클래스 구현
    - SystemState 조회/업데이트
    - 조건부 쓰기로 동시성 제어
    - 분산 락 구현
    - _요구사항: 7.3_
  
  - [ ] 6.2 데이터 모델 정의
    - SystemState 스키마
    - FailoverEvent 스키마
    - _요구사항: 7.3_

- [ ] 7. Failover Controller Lambda 구현
  - [ ] 7.1 FailoverController 클래스 구현
    - CloudWatch 이벤트 핸들러
    - 상태 기반 액션 결정 로직
    - _요구사항: 7.1, 7.2_
  
  - [ ] 7.2 EC2 DB1 → RDS1 Failover 로직 구현
    - RDS1 복제 중지
    - RDS1 Master 승격
    - ProxySQL 라우팅 업데이트
    - RDS2 복제 재구성
    - SNS 알림 전송
    - _요구사항: 3.1, 3.2, 3.3, 3.4, 3.5, 3.7_
  
  - [ ] 7.3 RDS1 → RDS2 Failover 로직 구현
    - DMS 태스크 중지
    - RDS2 Master 승격
    - ProxySQL 라우팅 업데이트
    - SNS 알림 전송
    - _요구사항: 4.1, 4.2, 4.3, 4.4, 4.6_
  
  - [ ]* 7.4 속성 테스트: 연속 헬스체크 실패 시 Failover 시작
    - **속성 3: 연속 헬스체크 실패 시 Failover 시작**
    - **검증 대상: 요구사항 3.1, 4.1**
  
  - [ ]* 7.5 속성 테스트: 상태 기반 액션 결정
    - **속성 7: 상태 기반 액션 결정**
    - **검증 대상: 요구사항 7.2**
  
  - [ ]* 7.6 속성 테스트: Failover 작업 멱등성
    - **속성 8: Failover 작업 멱등성**
    - **검증 대상: 요구사항 7.4**

- [ ] 8. 체크포인트 - Failover 로직 검증
  - 모든 테스트 통과 확인, 문제 발생 시 사용자에게 질문

- [ ] 9. Rollback 로직 구현
  - [ ] 9.1 EC2 DB1 복구 감지 로직 구현
    - 헬스체크 성공 감지
    - 복구 이벤트 트리거
    - _요구사항: 5.1_
  
  - [ ] 9.2 Rollback 프로세스 구현
    - EC2 DB1 데이터 동기화
    - EC2 DB1 Master 승격
    - RDS1 Slave 재구성
    - ProxySQL 라우팅 업데이트
    - SNS 알림 전송
    - _요구사항: 5.2, 5.3, 5.4, 5.5, 5.6, 5.8_
  
  - [ ]* 9.3 속성 테스트: EC2 DB1 복구 시 롤백 시작
    - **속성 5: EC2 DB1 복구 시 롤백 시작**
    - **검증 대상: 요구사항 5.2**
  
  - [ ]* 9.4 속성 테스트: Master 변경 시 복제 체인 재구성
    - **속성 4: Master 변경 시 복제 체인 재구성**
    - **검증 대상: 요구사항 2.5, 3.5, 5.5**

- [ ] 10. Replication Manager 구현
  - [ ] 10.1 ReplicationManager 클래스 구현
    - Master 설정 메서드
    - Slave 복제 설정 메서드
    - 복제 중지/시작 메서드
    - 복제 체인 재구성 메서드
    - _요구사항: 2.1, 2.2, 2.5, 2.6_

- [ ] 11. ProxySQL 클라이언트 구현
  - [ ] 11.1 ProxySQLClient 클래스 구현
    - Admin API 연결
    - 서버 상태 업데이트
    - 라우팅 규칙 업데이트
    - _요구사항: 1.3, 1.5_

- [ ] 12. 에러 처리 및 재시도 로직
  - [ ] 12.1 ErrorHandler 클래스 구현
    - 재시도 로직 (최대 3회)
    - 에러 로깅
    - SNS 알림 전송
    - _요구사항: 7.5, 7.6_

- [ ] 13. 체크포인트 - 전체 Failover/Rollback 검증
  - 모든 테스트 통과 확인, 문제 발생 시 사용자에게 질문

- [ ] 14. WAS 연결 설정
  - [ ] 14.1 WAS DB 연결 설정 가이드 작성
    - ProxySQL (NLB) 엔드포인트 연결
    - 커넥션 풀 설정
    - 재연결 정책 설정
    - _요구사항: 8.1, 8.2, 8.3_
  
  - [ ]* 14.2 속성 테스트: WAS 연결 실패 우아한 처리
    - **속성 9: WAS 연결 실패 우아한 처리**
    - **검증 대상: 요구사항 8.4**

- [ ] 15. CloudWatch 대시보드 설정
  - [ ] 15.1 대시보드 IaC 코드 작성
    - DB 상태 위젯
    - 복제 지연 위젯
    - Failover 이벤트 위젯
    - _요구사항: 6.7_

- [ ] 16. 최종 체크포인트 - 전체 시스템 검증
  - 모든 테스트 통과 확인, 문제 발생 시 사용자에게 질문

## 참고사항

- `*` 표시된 태스크는 선택적 테스트 태스크입니다
- 각 태스크는 특정 요구사항을 참조합니다
- 체크포인트에서 전체 검증을 수행합니다
- 속성 테스트는 pytest + Hypothesis로 구현합니다
