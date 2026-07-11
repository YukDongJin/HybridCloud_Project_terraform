import os
import json
import boto3
import pymysql
from datetime import datetime
from typing import Dict, Optional

# 환경 변수
DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
EC2_DB1_ENDPOINT = os.environ['EC2_DB1_ENDPOINT']
RDS1_ENDPOINT = os.environ['RDS1_ENDPOINT']
RDS2_ENDPOINT = os.environ['RDS2_ENDPOINT']

# AWS 클라이언트
dynamodb = boto3.resource('dynamodb')
cloudwatch = boto3.client('cloudwatch')
sns = boto3.client('sns')

table = dynamodb.Table(DYNAMODB_TABLE)

class HealthStatus:
    def __init__(self, is_healthy: bool, latency_ms: int, replication_lag: int = 0, error: str = None):
        self.is_healthy = is_healthy
        self.latency_ms = latency_ms
        self.replication_lag = replication_lag
        self.error = error

def check_db_health(endpoint: str, port: int = 3306) -> HealthStatus:
    """DB 연결 및 상태 확인"""
    start_time = datetime.now()
    
    try:
        # MySQL 연결 시도
        connection = pymysql.connect(
            host=endpoint.split(':')[0],
            port=port,
            user='admin',
            password=os.environ.get('DB_PASSWORD', 'password123'),
            connect_timeout=5,
            read_timeout=5
        )
        
        cursor = connection.cursor()
        
        # 간단한 쿼리로 응답 확인
        cursor.execute("SELECT 1")
        cursor.fetchone()
        
        # 복제 지연 확인 (Slave인 경우)
        replication_lag = 0
        try:
            cursor.execute("SHOW SLAVE STATUS")
            slave_status = cursor.fetchone()
            if slave_status:
                # Seconds_Behind_Master 값 추출
                replication_lag = slave_status[32] if slave_status[32] else 0
        except:
            pass  # Master인 경우 SLAVE STATUS 없음
        
        cursor.close()
        connection.close()
        
        latency_ms = int((datetime.now() - start_time).total_seconds() * 1000)
        
        return HealthStatus(
            is_healthy=True,
            latency_ms=latency_ms,
            replication_lag=replication_lag
        )
        
    except Exception as e:
        latency_ms = int((datetime.now() - start_time).total_seconds() * 1000)
        return HealthStatus(
            is_healthy=False,
            latency_ms=latency_ms,
            error=str(e)
        )

def get_current_state() -> Dict:
    """DynamoDB에서 현재 시스템 상태 조회"""
    try:
        response = table.get_item(
            Key={'pk': 'SYSTEM_STATE', 'sk': 'CURRENT'}
        )
        
        if 'Item' in response:
            return response['Item']
        else:
            # 초기 상태 생성
            initial_state = {
                'pk': 'SYSTEM_STATE',
                'sk': 'CURRENT',
                'ec2_db1_state': 'master',
                'rds1_state': 'slave',
                'rds2_state': 'standby',
                'current_master': 'ec2_db1',
                'ec2_db1_failure_count': 0,
                'rds1_failure_count': 0,
                'rds2_failure_count': 0,
                'updated_at': datetime.now().isoformat()
            }
            table.put_item(Item=initial_state)
            return initial_state
            
    except Exception as e:
        print(f"Error getting state: {e}")
        return None

def update_failure_count(db_name: str, is_healthy: bool, current_state: Dict) -> int:
    """장애 카운트 업데이트"""
    failure_key = f"{db_name}_failure_count"
    current_count = current_state.get(failure_key, 0)
    
    if is_healthy:
        new_count = 0  # 정상이면 카운트 리셋
    else:
        new_count = current_count + 1  # 장애면 카운트 증가
    
    # DynamoDB 업데이트
    try:
        table.update_item(
            Key={'pk': 'SYSTEM_STATE', 'sk': 'CURRENT'},
            UpdateExpression=f'SET {failure_key} = :count, updated_at = :time',
            ExpressionAttributeValues={
                ':count': new_count,
                ':time': datetime.now().isoformat()
            }
        )
    except Exception as e:
        print(f"Error updating failure count: {e}")
    
    return new_count

def publish_metrics(db_name: str, health: HealthStatus):
    """CloudWatch 메트릭 발행"""
    try:
        # DB 헬스 상태
        cloudwatch.put_metric_data(
            Namespace='DBMigration/Failover',
            MetricData=[
                {
                    'MetricName': 'DBHealthStatus',
                    'Dimensions': [{'Name': 'DBInstance', 'Value': db_name}],
                    'Value': 1 if health.is_healthy else 0,
                    'Unit': 'Count',
                    'Timestamp': datetime.now()
                },
                {
                    'MetricName': 'QueryLatency',
                    'Dimensions': [{'Name': 'DBInstance', 'Value': db_name}],
                    'Value': health.latency_ms,
                    'Unit': 'Milliseconds',
                    'Timestamp': datetime.now()
                }
            ]
        )
        
        # 복제 지연 (Slave인 경우)
        if health.replication_lag > 0:
            cloudwatch.put_metric_data(
                Namespace='DBMigration/Failover',
                MetricData=[
                    {
                        'MetricName': 'ReplicationLag',
                        'Dimensions': [{'Name': 'SlaveInstance', 'Value': db_name}],
                        'Value': health.replication_lag,
                        'Unit': 'Seconds',
                        'Timestamp': datetime.now()
                    }
                ]
            )
            
    except Exception as e:
        print(f"Error publishing metrics: {e}")

def send_alert(subject: str, message: str):
    """SNS 알림 전송"""
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message
        )
    except Exception as e:
        print(f"Error sending alert: {e}")

def lambda_handler(event, context):
    """Lambda 핸들러 - 10초마다 실행"""
    
    print("Starting health check...")
    
    # 현재 상태 조회
    current_state = get_current_state()
    if not current_state:
        return {'statusCode': 500, 'body': 'Failed to get current state'}
    
    # DB 엔드포인트 매핑
    db_endpoints = {
        'ec2_db1': EC2_DB1_ENDPOINT,
        'rds1': RDS1_ENDPOINT.split(':')[0],
        'rds2': RDS2_ENDPOINT.split(':')[0]
    }
    
    results = {}
    
    # 각 DB 헬스체크
    for db_name, endpoint in db_endpoints.items():
        print(f"Checking {db_name} ({endpoint})...")
        
        health = check_db_health(endpoint)
        results[db_name] = health
        
        # 메트릭 발행
        publish_metrics(db_name, health)
        
        # 장애 카운트 업데이트
        failure_count = update_failure_count(db_name, health.is_healthy, current_state)
        
        print(f"{db_name}: healthy={health.is_healthy}, latency={health.latency_ms}ms, "
              f"replication_lag={health.replication_lag}s, failure_count={failure_count}")
        
        # 3회 연속 실패 시 알림 (Failover Controller가 처리)
        if failure_count >= 3:
            alert_message = f"""
DB Health Check Alert

Database: {db_name}
Status: FAILED (3 consecutive failures)
Endpoint: {endpoint}
Error: {health.error if health.error else 'Connection timeout'}
Time: {datetime.now().isoformat()}

Failover Controller will be triggered automatically.
"""
            send_alert(
                subject=f"[CRITICAL] {db_name} Health Check Failed",
                message=alert_message
            )
        
        # 복제 지연 알림 (10초 초과)
        if health.replication_lag > 10:
            alert_message = f"""
Replication Lag Alert

Database: {db_name}
Replication Lag: {health.replication_lag} seconds
Threshold: 10 seconds
Time: {datetime.now().isoformat()}

Please investigate replication issues.
"""
            send_alert(
                subject=f"[WARNING] {db_name} Replication Lag",
                message=alert_message
            )
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Health check completed',
            'results': {
                db: {
                    'healthy': health.is_healthy,
                    'latency_ms': health.latency_ms,
                    'replication_lag': health.replication_lag
                }
                for db, health in results.items()
            }
        })
    }
