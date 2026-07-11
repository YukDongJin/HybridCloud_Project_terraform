import os
import json
import boto3
from datetime import datetime

dms = boto3.client('dms')
sns = boto3.client('sns')
dynamodb = boto3.resource('dynamodb')

RDS1_TO_RDS2_TASK_ARN = os.environ['RDS1_TO_RDS2_DMS_TASK_ARN']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']
DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']

table = dynamodb.Table(DYNAMODB_TABLE)

def check_task2_completion():
    """
    EventBridge에서 주기적으로 호출되어 Task 2 완료 여부 확인
    DynamoDB를 사용하여 알림 전송 여부를 영구 저장
    """
    try:
        # RDS1→RDS2 태스크 상태 확인
        response = dms.describe_replication_tasks(
            Filters=[
                {
                    'Name': 'replication-task-id',
                    'Values': ['db-failover-rds1-to-rds2']
                }
            ]
        )
        
        if not response['ReplicationTasks']:
            print("Task 2 not found")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Task 2 not found'})
            }
        
        task = response['ReplicationTasks'][0]
        status = task.get('Status', '')
        full_load_percent = task.get('ReplicationTaskStats', {}).get('FullLoadProgressPercent', 0)
        
        print(f"Task 2 status: {status}, Full Load: {full_load_percent}%")
        
        # DynamoDB에서 알림 전송 여부 확인
        db_response = table.get_item(Key={'pk': 'dms_notification', 'sk': 'task2_completion'})
        already_notified = db_response.get('Item', {}).get('notified', False)
        
        print(f"Already notified (from DynamoDB): {already_notified}")
        
        # Full Load 100% 완료 && 아직 알림 안 보냄
        if full_load_percent >= 100 and status == 'running' and not already_notified:
            print("Task 2 Full Load 100% complete! Sending completion notification...")
            
            # 전체 동기화 완료 알림
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="[SUCCESS] 전체 DB 동기화 완료",
                Message=f"모든 데이터베이스 동기화가 성공적으로 완료되었습니다!\n\n"
                       f"복제 체인:\n"
                       f"  DB1 (EC2) → RDS1 → RDS2\n\n"
                       f"상태:\n"
                       f"  ✓ DB1 → RDS1: 동기화 완료\n"
                       f"  ✓ RDS1 → RDS2: 동기화 완료\n\n"
                       f"시스템이 프로덕션 준비 완료되었습니다!"
            )
            
            # DynamoDB에 알림 전송 기록
            table.put_item(
                Item={
                    'pk': 'dms_notification',
                    'sk': 'task2_completion',
                    'notified': True,
                    'timestamp': datetime.utcnow().isoformat()
                }
            )
            
            print("Completion notification sent and recorded in DynamoDB!")
            
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Task 2 completion notification sent'})
            }
        else:
            print(f"Task 2 not complete yet or already notified (notified={already_notified})")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Task 2 not complete or already notified'})
            }
    
    except Exception as e:
        print(f"Error checking Task 2 completion: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def check_task1_completion():
    """
    EventBridge에서 주기적으로 호출되어 Task 1 완료 여부 확인
    Task 1 Full Load 100% 완료 시 Task 2 자동 시작
    """
    try:
        # DynamoDB에서 Task 1 모니터링 플래그 확인
        db_response = table.get_item(Key={'pk': 'dms_monitoring', 'sk': 'task1_started'})
        task1_monitoring = db_response.get('Item', {}).get('monitoring', False)
        
        if not task1_monitoring:
            print("Task 1 monitoring not active, skipping...")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Task 1 monitoring not active'})
            }
        
        print("Task 1 monitoring active, checking Full Load progress...")
        
        # DB1→RDS1 태스크 상태 확인
        response = dms.describe_replication_tasks(
            Filters=[
                {
                    'Name': 'replication-task-id',
                    'Values': ['db-failover-db1-to-rds1']
                }
            ]
        )
        
        if not response['ReplicationTasks']:
            print("Task 1 not found")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Task 1 not found'})
            }
        
        task = response['ReplicationTasks'][0]
        status = task.get('Status', '')
        full_load_percent = task.get('ReplicationTaskStats', {}).get('FullLoadProgressPercent', 0)
        
        print(f"Task 1 status: {status}, Full Load: {full_load_percent}%")
        
        # Full Load 100% 완료 확인
        if full_load_percent >= 100 and status == 'running':
            print("Task 1 Full Load 100% complete! Starting Task 2...")
            
            # RDS1→RDS2 DMS 태스크 상태 확인
            rds2_response = dms.describe_replication_tasks(
                Filters=[
                    {
                        'Name': 'replication-task-arn',
                        'Values': [RDS1_TO_RDS2_TASK_ARN]
                    }
                ]
            )
            
            if not rds2_response['ReplicationTasks']:
                raise Exception(f"RDS1→RDS2 DMS task not found: {RDS1_TO_RDS2_TASK_ARN}")
            
            task2_status = rds2_response['ReplicationTasks'][0]['Status']
            print(f"RDS1→RDS2 DMS task status: {task2_status}")
            
            # 이미 실행 중이면 스킵
            if task2_status in ['running', 'starting']:
                print("RDS1→RDS2 DMS task already running, removing monitoring flag...")
                # 모니터링 플래그 제거
                table.delete_item(Key={'pk': 'dms_monitoring', 'sk': 'task1_started'})
                return {
                    'statusCode': 200,
                    'body': json.dumps({'message': 'Task 2 already running'})
                }
            
            # RDS1→RDS2 DMS 태스크 시작
            dms.start_replication_task(
                ReplicationTaskArn=RDS1_TO_RDS2_TASK_ARN,
                StartReplicationTaskType='start-replication'
            )
            
            print("RDS1→RDS2 DMS task started successfully!")
            
            # 모니터링 플래그 제거
            table.delete_item(Key={'pk': 'dms_monitoring', 'sk': 'task1_started'})
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'Task 2 started successfully',
                    'task_arn': RDS1_TO_RDS2_TASK_ARN
                })
            }
        else:
            print(f"Task 1 Full Load not complete yet ({full_load_percent}%), waiting...")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Waiting for Task 1 completion'})
            }
    
    except Exception as e:
        print(f"Error checking Task 1 completion: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def lambda_handler(event, context):
    """
    DMS 태스크 상태 변경 이벤트를 감지하여 RDS1→RDS2 DMS 자동 시작
    
    호출 방법:
    1. DMS Event Subscription → SNS → Lambda (DMS 이벤트)
    2. EventBridge Schedule → Lambda (주기적 Task 1/2 완료 체크)
    """
    
    print(f"Event received: {json.dumps(event)}")
    
    try:
        # EventBridge 스케줄 호출
        if event.get('source') == 'eventbridge.schedule':
            action = event.get('action', '')
            
            if action == 'check_task1_completion':
                print("EventBridge scheduled check: Checking Task 1 completion...")
                return check_task1_completion()
            elif action == 'check_task2_completion':
                print("EventBridge scheduled check: Checking Task 2 completion...")
                return check_task2_completion()
            else:
                print(f"Unknown EventBridge action: {action}")
                return {
                    'statusCode': 400,
                    'body': json.dumps({'error': 'Unknown action'})
                }
        
        # SNS에서 직접 온 이벤트 파싱
        if 'Records' in event and event['Records']:
            sns_record = event['Records'][0]['Sns']
            
            # SNS Message 원본 출력 (디버깅용)
            print(f"Raw SNS Message: {sns_record.get('Message', 'N/A')}")
            
            # Message는 JSON 문자열일 수도 있고 일반 텍스트일 수도 있음
            try:
                sns_message = json.loads(sns_record['Message'])
                print(f"Parsed SNS Message (JSON): {json.dumps(sns_message, indent=2)}")
            except (json.JSONDecodeError, TypeError) as e:
                # JSON이 아닌 경우 일반 텍스트로 처리
                print(f"SNS message is not JSON, treating as plain text: {e}")
                sns_message = {'Message': sns_record.get('Message', '')}
            
            # DMS 이벤트 필드 추출 (여러 가능한 필드명 시도)
            event_message = sns_message.get('Event Message', 
                           sns_message.get('Message', 
                           sns_message.get('message', '')))
            
            source_id = sns_message.get('SourceId', 
                       sns_message.get('Source ID',
                       sns_message.get('Event Source ARN',
                       sns_message.get('SourceIdentifier',
                       sns_message.get('SourceArn', '')))))
            
            print(f"Extracted Event Message: {event_message}")
            print(f"Extracted Source ID: {source_id}")
            
            # Lambda 자신이 보낸 메시지 무시 (무한 루프 방지)
            sns_subject = sns_record.get('Subject', '')
            if '[ERROR]' in sns_subject or '[SUCCESS]' in sns_subject:
                print("Ignoring Lambda's own notification message")
                return {
                    'statusCode': 200,
                    'body': json.dumps({'message': 'Lambda notification ignored'})
                }
            
            # CloudWatch Alarm 메시지 무시
            if 'AlarmName' in str(sns_message) or 'AlarmArn' in str(sns_message):
                print("Ignoring CloudWatch Alarm message")
                return {
                    'statusCode': 200,
                    'body': json.dumps({'message': 'CloudWatch Alarm ignored'})
                }
            
            # Source ID가 비어있으면 전체 메시지에서 태스크 ID 찾기 (fallback)
            full_message = json.dumps(sns_message) + ' ' + event_message + ' ' + sns_subject
            
            # DB1→RDS1 태스크인지 확인 (Task ID로 확인)
            is_db1_to_rds1 = ('db1-to-rds1' in source_id.lower() or 
                             'db-failover-db1-to-rds1' in source_id.lower() or
                             'db1-to-rds1' in full_message.lower() or
                             'db-failover-db1-to-rds1' in full_message.lower())
            
            is_rds1_to_rds2 = ('rds1-to-rds2' in source_id.lower() or 
                              'db-failover-rds1-to-rds2' in source_id.lower() or
                              'rds1-to-rds2' in full_message.lower() or
                              'db-failover-rds1-to-rds2' in full_message.lower())
            
            print(f"Task identification - DB1→RDS1: {is_db1_to_rds1}, RDS1→RDS2: {is_rds1_to_rds2}")
            
            # DB1→RDS1 태스크 state change 이벤트 처리
            if is_db1_to_rds1 and ('started' in event_message.lower() or 'state change' in event_message.lower()):
                print(f"DB1→RDS1 DMS task started! Enabling monitoring...")
                
                # DynamoDB에 Task 1 모니터링 플래그 저장
                table.put_item(
                    Item={
                        'pk': 'dms_monitoring',
                        'sk': 'task1_started',
                        'monitoring': True,
                        'timestamp': datetime.utcnow().isoformat()
                    }
                )
                
                print("Task 1 monitoring enabled. EventBridge will check completion every minute.")
                
                return {
                    'statusCode': 200,
                    'body': json.dumps({'message': 'Task 1 monitoring enabled'})
                }
            
            # RDS1→RDS2 태스크 state change 이벤트 처리 (완료 확인)
            elif is_rds1_to_rds2 and ('started' in event_message.lower() or 'state change' in event_message.lower()):
                print(f"RDS1→RDS2 DMS task state change detected. Checking Full Load progress...")
                
                # RDS1→RDS2 태스크 상태 확인
                rds2_response = dms.describe_replication_tasks(
                    Filters=[
                        {
                            'Name': 'replication-task-id',
                            'Values': ['db-failover-rds1-to-rds2']
                        }
                    ]
                )
                
                if rds2_response['ReplicationTasks']:
                    rds2_task = rds2_response['ReplicationTasks'][0]
                    rds2_status = rds2_task.get('Status', '')
                    full_load_percent = rds2_task.get('ReplicationTaskStats', {}).get('FullLoadProgressPercent', 0)
                    
                    print(f"RDS1→RDS2 status: {rds2_status}, Full Load: {full_load_percent}%")
                    
                    # Full Load가 100% 완료되었는지 확인
                    if full_load_percent >= 100:
                        print("RDS1→RDS2 Full Load 100% complete! Checking if notification already sent...")
                        
                        # DynamoDB에서 알림 전송 여부 확인 (중복 방지)
                        db_response = table.get_item(Key={'pk': 'dms_notification', 'sk': 'task2_completion'})
                        already_notified = db_response.get('Item', {}).get('notified', False)
                        
                        print(f"Already notified (from DynamoDB): {already_notified}")
                        
                        if not already_notified:
                            print("Sending completion notification...")
                            
                            # 전체 동기화 완료 알림
                            sns.publish(
                                TopicArn=SNS_TOPIC_ARN,
                                Subject="[SUCCESS] 전체 DB 동기화 완료",
                                Message=f"모든 데이터베이스 동기화가 성공적으로 완료되었습니다!\n\n"
                                       f"복제 체인:\n"
                                       f"  DB1 (EC2) → RDS1 → RDS2\n\n"
                                       f"상태:\n"
                                       f"  ✓ DB1 → RDS1: 동기화 완료\n"
                                       f"  ✓ RDS1 → RDS2: 동기화 완료\n\n"
                                       f"시스템이 프로덕션 준비 완료되었습니다!"
                            )
                            
                            # DynamoDB에 알림 전송 기록
                            table.put_item(
                                Item={
                                    'pk': 'dms_notification',
                                    'sk': 'task2_completion',
                                    'notified': True,
                                    'timestamp': datetime.utcnow().isoformat()
                                }
                            )
                            
                            print("Completion notification sent and recorded in DynamoDB!")
                            
                            return {
                                'statusCode': 200,
                                'body': json.dumps({'message': 'All synchronization complete'})
                            }
                        else:
                            print("Notification already sent, skipping...")
                            return {
                                'statusCode': 200,
                                'body': json.dumps({'message': 'Notification already sent'})
                            }
                    else:
                        print(f"RDS1→RDS2 Full Load not complete yet ({full_load_percent}%), waiting...")
                        return {
                            'statusCode': 200,
                            'body': json.dumps({'message': 'Waiting for RDS2 Full Load completion'})
                        }
                else:
                    print("RDS1→RDS2 task not found in describe response")
                    return {
                        'statusCode': 200,
                        'body': json.dumps({'message': 'Task not found'})
                    }
            
            else:
                print("Event not related to DB1→RDS1 task, ignoring...")
                return {
                    'statusCode': 200,
                    'body': json.dumps({'message': 'Event ignored'})
                }
        else:
            print("No SNS Records found in event")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'No SNS Records'})
            }
    
    except Exception as e:
        error_msg = str(e)
        print(f"Error: {error_msg}")
        
        # 에러 발생 시 SNS 알림 보내지 않음 (무한 루프 방지)
        # 로그만 남기고 조용히 실패
        
        return {
            'statusCode': 500,
            'body': json.dumps({'error': error_msg})
        }
