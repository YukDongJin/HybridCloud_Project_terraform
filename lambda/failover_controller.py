import os
import json
import boto3
import pymysql
from datetime import datetime
from typing import Dict, Optional, Tuple
import uuid
import time

# 환경 변수
DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
EC2_DB1_ENDPOINT = os.environ['EC2_DB1_ENDPOINT']
RDS1_ENDPOINT = os.environ['RDS1_ENDPOINT']
RDS2_ENDPOINT = os.environ['RDS2_ENDPOINT']
PROXYSQL_ENDPOINTS = os.environ['PROXYSQL_ENDPOINTS'].split(',')

# AWS 클라이언트
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')
dms = boto3.client('dms')

table = dynamodb.Table(DYNAMODB_TABLE)

class FailoverController:
    
    def __init__(self):
        self.db_endpoints = {
            'ec2_db1': EC2_DB1_ENDPOINT,
            'rds1': RDS1_ENDPOINT.split(':')[0],
            'rds2': RDS2_ENDPOINT.split(':')[0]
        }
    
    def get_current_state(self) -> Dict:
        """현재 시스템 상태 조회"""
        try:
            response = table.get_item(
                Key={'pk': 'SYSTEM_STATE', 'sk': 'CURRENT'}
            )
            return response.get('Item', {})
        except Exception as e:
            print(f"Error getting state: {e}")
            return {}
    
    def update_state(self, updates: Dict) -> bool:
        """시스템 상태 업데이트"""
        try:
            update_expr = 'SET ' + ', '.join([f"{k} = :{k}" for k in updates.keys()])
            update_expr += ', updated_at = :updated_at'
            
            expr_values = {f":{k}": v for k, v in updates.items()}
            expr_values[':updated_at'] = datetime.now().isoformat()
            
            table.update_item(
                Key={'pk': 'SYSTEM_STATE', 'sk': 'CURRENT'},
                UpdateExpression=update_expr,
                ExpressionAttributeValues=expr_values
            )
            return True
        except Exception as e:
            print(f"Error updating state: {e}")
            return False
    
    def log_failover_event(self, event_type: str, from_db: str, to_db: str, 
                          status: str, error: str = None):
        """Failover 이벤트 로깅"""
        try:
            event_id = str(uuid.uuid4())
            timestamp = datetime.now().isoformat()
            
            table.put_item(
                Item={
                    'pk': 'FAILOVER_EVENT',
                    'sk': f"{timestamp}#{event_id}",
                    'event_type': event_type,
                    'from_db': from_db,
                    'to_db': to_db,
                    'status': status,
                    'error_message': error,
                    'timestamp': timestamp
                }
            )
        except Exception as e:
            print(f"Error logging event: {e}")
    
    def execute_mysql_command(self, endpoint: str, command: str) -> Tuple[bool, str]:
        """MySQL 명령 실행"""
        try:
            connection = pymysql.connect(
                host=endpoint,
                port=3306,
                user='admin',
                password=os.environ.get('DB_PASSWORD', 'password123'),
                connect_timeout=10
            )
            
            cursor = connection.cursor()
            cursor.execute(command)
            connection.commit()
            cursor.close()
            connection.close()
            
            return True, "Success"
        except Exception as e:
            return False, str(e)
    
    def stop_replication(self, slave_endpoint: str) -> bool:
        """복제 중지"""
        print(f"Stopping replication on {slave_endpoint}...")
        success, msg = self.execute_mysql_command(slave_endpoint, "STOP SLAVE")
        if success:
            print(f"Replication stopped on {slave_endpoint}")
        else:
            print(f"Failed to stop replication: {msg}")
        return success
    
    def promote_to_master(self, endpoint: str) -> bool:
        """Slave를 Master로 승격"""
        print(f"Promoting {endpoint} to master...")
        
        # 복제 중지
        if not self.stop_replication(endpoint):
            return False
        
        # Read-only 해제
        success, msg = self.execute_mysql_command(endpoint, "SET GLOBAL read_only = 0")
        if success:
            print(f"{endpoint} promoted to master")
        else:
            print(f"Failed to promote: {msg}")
        
        return success
    
    def update_proxysql_routing(self, new_master: str) -> bool:
        """ProxySQL 노드 간 순차 업데이트 및 검증"""
        master_endpoint = self.db_endpoints[new_master]
        update_sql = f"""
        UPDATE mysql_servers SET status='OFFLINE_HARD' WHERE hostgroup_id=10;
        REPLACE INTO mysql_servers (hostgroup_id, hostname, port, weight, status) 
        VALUES (10, '{master_endpoint}', 3306, 1000, 'ONLINE');
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
        """
        success_count = 0
        for i, endpoint in enumerate(PROXYSQL_ENDPOINTS):
            try:
                if i > 0:
                    time.sleep(2)  # 동기화 대기
                
                conn = pymysql.connect(
                    host=endpoint.strip(),
                    port=6032,
                    user='radmin',
                    password='radmin',
                    connect_timeout=5
                )
                cur = conn.cursor()
                
                for sql in update_sql.strip().split(';'):
                    if sql.strip():
                        cur.execute(sql.strip())
                
                # 검증 로직
                cur.execute(
                    f"SELECT hostname FROM runtime_mysql_servers "
                    f"WHERE hostgroup_id=10 AND hostname='{master_endpoint}'"
                )
                if cur.fetchone():
                    success_count += 1
                
                conn.commit()
                conn.close()
            except Exception as e:
                print(f"ProxySQL {endpoint} update failed: {e}")
        
        return success_count == len(PROXYSQL_ENDPOINTS)
    
    def stop_dms_task(self, task_arn: str) -> bool:
        """DMS 복제 태스크 중지"""
        try:
            print(f"Stopping DMS task...")
            dms.stop_replication_task(ReplicationTaskArn=task_arn)
            print("DMS task stopped")
            return True
        except Exception as e:
            if 'InvalidResourceStateFault' in str(e):
                print(f"DMS task is already stopped or not running. Proceeding...")
                return True
            
            print(f"Failed to stop DMS task: {e}")
            return False
    
    def execute_failover_ec2_to_rds1(self) -> bool:
        """EC2 DB1 → RDS1 Failover (DMS 기반)"""
        print("=== Starting Failover: EC2 DB1 → RDS1 ===")
        
        self.log_failover_event('failover', 'ec2_db1', 'rds1', 'initiated')
        
        try:
            # 1. DMS 태스크 중지 (DB1 → RDS1 복제 중지)
            dms_task_arn = os.environ.get('DMS_TASK_ARN')
            if dms_task_arn:
                print("Stopping DMS task (DB1 → RDS1)...")
                self.stop_dms_task(dms_task_arn)
            
            # 2. RDS1은 이미 read_only=OFF 상태
            # DMS 중지만으로 RDS1이 자동으로 Master 역할 수행
            print(f"RDS1 is now master (read_only=OFF by default)")
            
            # 3. ProxySQL 라우팅 업데이트
            if not self.update_proxysql_routing('rds1'):
                raise Exception("Failed to update ProxySQL routing")
            
            # 4. 상태 업데이트
            self.update_state({
                'ec2_db1_state': 'failed',
                'rds1_state': 'master',
                'current_master': 'rds1',
                'last_failover_time': datetime.now().isoformat()
            })
            
            # 5. 알림 전송
            self.send_notification(
                subject="[SUCCESS] Failover Completed: EC2 DB1 → RDS1",
                message=f"Failover completed successfully at {datetime.now().isoformat()}\n"
                       f"New Master: RDS1\n"
                       f"Previous Master: EC2 DB1 (FAILED)\n"
                       f"DMS task (DB1 → RDS1) stopped"
            )
            
            self.log_failover_event('failover', 'ec2_db1', 'rds1', 'completed')
            print("=== Failover Completed Successfully ===")
            return True
            
        except Exception as e:
            error_msg = str(e)
            print(f"Failover failed: {error_msg}")
            self.log_failover_event('failover', 'ec2_db1', 'rds1', 'failed', error_msg)
            self.send_notification(
                subject="[FAILED] Failover Failed: EC2 DB1 → RDS1",
                message=f"Failover failed at {datetime.now().isoformat()}\n"
                       f"Error: {error_msg}"
            )
            return False
    
    def execute_failover_rds1_to_rds2(self) -> bool:
        """RDS1 → RDS2 Failover (DMS 사용)"""
        print("=== Starting Failover: RDS1 → RDS2 ===")
        
        self.log_failover_event('failover', 'rds1', 'rds2', 'initiated')
        
        try:
            # 1. DMS 태스크 중지 (RDS1 → RDS2 복제 중지)
            rds1_to_rds2_task_arn = os.environ.get('RDS1_TO_RDS2_DMS_TASK_ARN')
            if rds1_to_rds2_task_arn:
                print("Stopping DMS task (RDS1 → RDS2)...")
                self.stop_dms_task(rds1_to_rds2_task_arn)
            
            # 2. RDS2는 이미 read_only=OFF 상태
            # DMS 중지만으로 RDS2가 자동으로 Master 역할 수행
            print(f"RDS2 is now master (read_only=OFF by default)")
            
            # 3. ProxySQL 라우팅 업데이트
            if not self.update_proxysql_routing('rds2'):
                raise Exception("Failed to update ProxySQL routing")
            
            # 4. 상태 업데이트
            self.update_state({
                'rds1_state': 'failed',
                'rds2_state': 'master',
                'current_master': 'rds2',
                'last_failover_time': datetime.now().isoformat()
            })
            
            # 5. 알림 전송
            self.send_notification(
                subject="[SUCCESS] Failover Completed: RDS1 → RDS2",
                message=f"Failover completed successfully at {datetime.now().isoformat()}\n"
                       f"New Master: RDS2\n"
                       f"Previous Master: RDS1 (FAILED)\n"
                       f"DMS task (RDS1 → RDS2) stopped"
            )
            
            self.log_failover_event('failover', 'rds1', 'rds2', 'completed')
            print("=== Failover Completed Successfully ===")
            return True
            
        except Exception as e:
            error_msg = str(e)
            print(f"Failover failed: {error_msg}")
            self.log_failover_event('failover', 'rds1', 'rds2', 'failed', error_msg)
            self.send_notification(
                subject="[FAILED] Failover Failed: RDS1 → RDS2",
                message=f"Failover failed at {datetime.now().isoformat()}\n"
                       f"Error: {error_msg}"
            )
            return False
    
    def execute_rollback_to_ec2(self) -> bool:
        """RDS1 → EC2 DB1 Rollback (역방향 DMS 동기화 포함)"""
        print("=== Starting Rollback: RDS1 → EC2 DB1 ===")
        
        self.log_failover_event('rollback', 'rds1', 'ec2_db1', 'initiated')
        
        try:
            # 1. 역방향 DMS 태스크 시작 (RDS1 → DB1)
            rds1_to_db1_task_arn = os.environ.get('RDS1_TO_DB1_DMS_TASK_ARN')
            if rds1_to_db1_task_arn:
                print("Waiting for DB1 MySQL to be fully ready (20 seconds)...")
                time.sleep(20)

                print("Starting reverse DMS task (RDS1 → DB1)...")
                # Endpoint 연결 실패 시 재시도 (최대 5회, 15초 간격)
                max_retries = 5
                retry_delay = 15
                task_started = False

                for attempt in range(max_retries):
                    try:
                        dms.start_replication_task(
                            ReplicationTaskArn=rds1_to_db1_task_arn,
                            StartReplicationTaskType='start-replication'
                        )                    
                        print(f"Reverse DMS task started successfully (attempt {attempt + 1})")
                        task_started = True
                        break
                    except Exception as e:
                        error_msg = str(e)
                        # Endpoint 연결 실패 에러인 경우에만 재시도
                        if ('Test connection' in error_msg or 'connection refused' in error_msg or 'Cannot connect' in error_msg) and attempt < max_retries - 1:
                            print(f"DB1 MySQL not ready yet (attempt {attempt + 1}/{max_retries})")
                            print(f"Error: {error_msg}")
                            print(f"Retrying in {retry_delay} seconds...")
                            time.sleep(retry_delay)
                        else:
                            # 다른 에러이거나 최대 재시도 횟수 초과
                            raise e
    
                if not task_started:
                    print("Warning: Failed to start reverse DMS task after all retries")
                else:
                    print("Reverse DMS task started, waiting for synchronization...")

                    # 동기화 대기 (최대 30초)
                    for i in range(120):  # 최대 2분 대기
                        time.sleep(1)
                        response = dms.describe_replication_tasks(
                            Filters=[{'Name': 'replication-task-arn', 'Values': [rds1_to_db1_task_arn]}]
                        )
                        if response['ReplicationTasks']:
                            task = response['ReplicationTasks'][0]
                            status = task['Status']
                            stats = task.get('ReplicationTaskStats', {})
                            full_load_percent = stats.get('FullLoadProgressPercent', 0)
        
                            if status == 'running' and full_load_percent == 100:
                                print(f"Reverse DMS Full Load completed after {i+1} seconds")
                                break
                    
                    # 역방향 DMS 중지
                    print("Stopping reverse DMS task...")
                    self.stop_dms_task(rds1_to_db1_task_arn)
                    
            
            # 2. EC2 DB1을 Master로 승격 (read_only 해제)
            print("Promoting EC2 DB1 to master...")
            success, msg = self.execute_mysql_command(
                self.db_endpoints['ec2_db1'],
                "SET GLOBAL read_only = 0"
            )
            if not success:
                raise Exception(f"Failed to promote EC2 DB1: {msg}")
            
            print("EC2 DB1 promoted to master")
            
            # 3. ProxySQL 라우팅 업데이트
            if not self.update_proxysql_routing('ec2_db1'):
                raise Exception("Failed to update ProxySQL routing")
            
            # 4. 정방향 DMS 태스크 재시작 (DB1 → RDS1 복제 재개)
            dms_task_arn = os.environ.get('DMS_TASK_ARN')
            if dms_task_arn:
                print("Restarting forward DMS task (DB1 → RDS1)...")
                try:                        
                    response = dms.describe_replication_tasks(
                        Filters=[{'Name': 'replication-task-arn', 'Values': [dms_task_arn]}]
                    )
                    
                    if response['ReplicationTasks']:
                        task_status = response['ReplicationTasks'][0]['Status']
                        print(f"Current forward DMS task status: {task_status}")
                        
                        if task_status == 'stopped':
                            dms.start_replication_task(
                                ReplicationTaskArn=dms_task_arn,
                                StartReplicationTaskType='start-replication'
                            )
                            print("Forward DMS task started (start-replication)")
                        elif task_status == 'failed':
                            dms.start_replication_task(
                                ReplicationTaskArn=dms_task_arn,
                                StartReplicationTaskType='resume-processing'
                            )
                            print("Forward DMS task resumed (resume-processing from failed state)")
                        elif task_status in ['running', 'starting']:
                            print("Forward DMS task already running")
                        else:
                            dms.start_replication_task(
                                ReplicationTaskArn=dms_task_arn,
                                StartReplicationTaskType='resume-processing'
                            )
                            print("Forward DMS task resumed")
                except Exception as e:
                    print(f"Warning: Failed to restart forward DMS task: {e}")
            
            # 5. 상태 업데이트
            self.update_state({
                'ec2_db1_state': 'master',
                'rds1_state': 'slave',
                'current_master': 'ec2_db1',
                'last_rollback_time': datetime.now().isoformat()
            })
            
            # 6. 알림 전송
            self.send_notification(
                subject="[SUCCESS] Rollback Completed: RDS1 → EC2 DB1",
                message=f"Rollback completed successfully at {datetime.now().isoformat()}\n"
                       f"New Master: EC2 DB1\n"
                       f"Previous Master: RDS1\n"
                       f"Reverse DMS (RDS1→DB1) synchronized and stopped\n"
                       f"Forward DMS (DB1→RDS1) restarted"
            )
            
            self.log_failover_event('rollback', 'rds1', 'ec2_db1', 'completed')
            print("=== Rollback Completed Successfully ===")
            return True
            
        except Exception as e:
            error_msg = str(e)
            print(f"Rollback failed: {error_msg}")
            self.log_failover_event('rollback', 'rds1', 'ec2_db1', 'failed', error_msg)
            self.send_notification(
                subject="[FAILED] Rollback Failed: RDS1 → EC2 DB1",
                message=f"Rollback failed at {datetime.now().isoformat()}\n"
                       f"Error: {error_msg}"
            )
            return False
    
    def execute_rollback_to_rds1(self) -> bool:
        """RDS2 → RDS1 Rollback (역방향 DMS 동기화 포함)"""
        print("=== Starting Rollback: RDS2 → RDS1 ===")
        
        self.log_failover_event('rollback', 'rds2', 'rds1', 'initiated')
        
        try:
            # 1. 역방향 DMS 태스크 시작 (RDS2 → RDS1)
            rds2_to_rds1_task_arn = os.environ.get('RDS2_TO_RDS1_DMS_TASK_ARN')
            if rds2_to_rds1_task_arn:
                print("Starting reverse DMS task (RDS2 → RDS1)...")
                try:
                    dms.start_replication_task(
                        ReplicationTaskArn=rds2_to_rds1_task_arn,
                        StartReplicationTaskType='start-replication'
                    )
                    print("Reverse DMS task started, waiting for synchronization...")
                    
                    # 동기화 대기 (최대 30초)
                    for i in range(120):  # 최대 2분 대기
                        time.sleep(1)
                        response = dms.describe_replication_tasks(
                            Filters=[{'Name': 'replication-task-arn', 'Values': [rds2_to_rds1_task_arn]}]
                        )
                        if response['ReplicationTasks']:
                            task = response['ReplicationTasks'][0]
                            status = task['Status']
                            stats = task.get('ReplicationTaskStats', {})
                            full_load_percent = stats.get('FullLoadProgressPercent', 0)
        
                            if status == 'running' and full_load_percent == 100:
                                print(f"Reverse DMS Full Load completed after {i+1} seconds")
                                break
                    
                    # 역방향 DMS 중지
                    print("Stopping reverse DMS task...")
                    self.stop_dms_task(rds2_to_rds1_task_arn)
                    
                except Exception as e:
                    print(f"Warning: Reverse DMS sync failed: {e}")
            
            # 2. RDS1은 이미 read_only=OFF 상태
            print("RDS1 is now master (read_only=OFF by default)")
            
            # 3. ProxySQL 라우팅 업데이트
            if not self.update_proxysql_routing('rds1'):
                raise Exception("Failed to update ProxySQL routing")
            
            # 4. 정방향 DMS 태스크 재시작 (RDS1 → RDS2 복제 재개)
            rds1_to_rds2_task_arn = os.environ.get('RDS1_TO_RDS2_DMS_TASK_ARN')
            if rds1_to_rds2_task_arn:
                print("Restarting forward DMS task (RDS1 → RDS2)...")
                try:
                    response = dms.describe_replication_tasks(
                        Filters=[{'Name': 'replication-task-arn', 'Values': [rds1_to_rds2_task_arn]}]
                    )
                    
                    if response['ReplicationTasks']:
                        task_status = response['ReplicationTasks'][0]['Status']
                        print(f"Current forward DMS task status: {task_status}")
                        
                        if task_status == 'stopped':
                            dms.start_replication_task(
                                ReplicationTaskArn=rds1_to_rds2_task_arn,
                                StartReplicationTaskType='start-replication'
                            )
                            print("Forward DMS task started (start-replication)")
                        elif task_status == 'failed':
                            dms.start_replication_task(
                                ReplicationTaskArn=rds1_to_rds2_task_arn,
                                StartReplicationTaskType='resume-processing'
                            )
                            print("Forward DMS task resumed (resume-processing from failed state)")
                        elif task_status in ['running', 'starting']:
                            print("Forward DMS task already running")
                        else:
                            dms.start_replication_task(
                                ReplicationTaskArn=rds1_to_rds2_task_arn,
                                StartReplicationTaskType='resume-processing'
                            )
                            print("Forward DMS task resumed")
                except Exception as e:
                    print(f"Warning: Failed to restart forward DMS task: {e}")
            
            # 5. 상태 업데이트
            self.update_state({
                'rds1_state': 'master',
                'rds2_state': 'standby',
                'current_master': 'rds1',
                'last_rollback_time': datetime.now().isoformat()
            })
            
            # 6. 알림 전송
            self.send_notification(
                subject="[SUCCESS] Rollback Completed: RDS2 → RDS1",
                message=f"Rollback completed successfully at {datetime.now().isoformat()}\n"
                       f"New Master: RDS1\n"
                       f"Previous Master: RDS2\n"
                       f"Reverse DMS (RDS2→RDS1) synchronized and stopped\n"
                       f"Forward DMS (RDS1→RDS2) restarted"
            )
            
            self.log_failover_event('rollback', 'rds2', 'rds1', 'completed')
            print("=== Rollback Completed Successfully ===")
            return True
            
        except Exception as e:
            error_msg = str(e)
            print(f"Rollback failed: {error_msg}")
            self.log_failover_event('rollback', 'rds2', 'rds1', 'failed', error_msg)
            self.send_notification(
                subject="[FAILED] Rollback Failed: RDS2 → RDS1",
                message=f"Rollback failed at {datetime.now().isoformat()}\n"
                       f"Error: {error_msg}"
            )
            return False
    
    def send_notification(self, subject: str, message: str):
        """SNS 알림 전송"""
        try:
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=subject,
                Message=message
            )
        except Exception as e:
            print(f"Failed to send notification: {e}")
    
    def decide_action(self, current_state: Dict) -> Optional[str]:
        """현재 상태 기반으로 액션 결정"""
        current_master = current_state.get('current_master', 'ec2_db1')
        
        ec2_failures = current_state.get('ec2_db1_failure_count', 0)
        rds1_failures = current_state.get('rds1_failure_count', 0)
        rds2_failures = current_state.get('rds2_failure_count', 0)
        
        ec2_state = current_state.get('ec2_db1_state', 'master')
        rds1_state = current_state.get('rds1_state', 'slave')
        
        print(f"Current master: {current_master}")
        print(f"Failure counts - EC2: {ec2_failures}, RDS1: {rds1_failures}, RDS2: {rds2_failures}")
        print(f"States - EC2: {ec2_state}, RDS1: {rds1_state}")
        
        # Rollback 시나리오 1: EC2 DB1 복구 → Master로 복귀
        if current_master == 'rds1' and ec2_failures == 0 and ec2_state == 'failed':
            print("EC2 DB1 recovered, initiating rollback to EC2 DB1")
            return 'rollback_to_ec2'
        
        # Rollback 시나리오 2: RDS1 복구 → Master로 복귀 (EC2가 여전히 실패한 경우)
        if current_master == 'rds2' and rds1_failures == 0 and rds1_state == 'failed' and ec2_state == 'failed':
            print("RDS1 recovered, initiating rollback to RDS1")
            return 'rollback_to_rds1'
        
        # Failover 시나리오 1: EC2 DB1이 Master이고 3회 연속 실패 → RDS1로 Failover
        if current_master == 'ec2_db1' and ec2_failures >= 3:
            return 'failover_ec2_to_rds1'
        
        # Failover 시나리오 2: RDS1이 Master이고 3회 연속 실패 → RDS2로 Failover
        if current_master == 'rds1' and rds1_failures >= 3:
            return 'failover_rds1_to_rds2'
        
        # 액션 불필요
        return None

def lambda_handler(event, context):
    """Lambda 핸들러 - CloudWatch 알람에서 트리거"""
    
    print("Failover Controller triggered")
    print(f"Event: {json.dumps(event)}")
    
    # Warmup 이벤트 무시
    if event.get('warmup'):
        print("Warmup event received, keeping Lambda warm...")
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Warmup successful'})
        }
    
    controller = FailoverController()
    
    # 현재 상태 조회
    current_state = controller.get_current_state()
    if not current_state:
        return {'statusCode': 500, 'body': 'Failed to get current state'}
    
    # 액션 결정
    action = controller.decide_action(current_state)
    
    if action == 'failover_ec2_to_rds1':
        success = controller.execute_failover_ec2_to_rds1()
        return {
            'statusCode': 200 if success else 500,
            'body': json.dumps({'action': action, 'success': success})
        }
    
    elif action == 'failover_rds1_to_rds2':
        success = controller.execute_failover_rds1_to_rds2()
        return {
            'statusCode': 200 if success else 500,
            'body': json.dumps({'action': action, 'success': success})
        }
    
    elif action == 'rollback_to_ec2':
        success = controller.execute_rollback_to_ec2()
        return {
            'statusCode': 200 if success else 500,
            'body': json.dumps({'action': action, 'success': success})
        }
    
    elif action == 'rollback_to_rds1':
        success = controller.execute_rollback_to_rds1()
        return {
            'statusCode': 200 if success else 500,
            'body': json.dumps({'action': action, 'success': success})
        }
    
    else:
        print("No action required")
        return {
            'statusCode': 200,
            'body': json.dumps({'action': 'none', 'message': 'No action required'})
        }
