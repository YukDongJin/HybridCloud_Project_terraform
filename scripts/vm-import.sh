#!/bin/bash

# VM Import 스크립트
# VM Workstation에서 내보낸 OVA 파일을 AWS로 가져옵니다

set -e

PROJECT_NAME="db-migration-failover"
REGION="ap-northeast-2"
S3_BUCKET="${PROJECT_NAME}-vm-import-$(date +%s)"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== VM Import 스크립트 ===${NC}"

# 1. S3 버킷 생성
echo -e "${YELLOW}1. S3 버킷 생성 중...${NC}"
aws s3 mb s3://${S3_BUCKET} --region ${REGION}

# 2. VM Import/Export IAM 역할 생성
echo -e "${YELLOW}2. IAM 역할 생성 중...${NC}"
cat > trust-policy.json <<EOF
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Effect": "Allow",
         "Principal": { "Service": "vmie.amazonaws.com" },
         "Action": "sts:AssumeRole",
         "Condition": {
            "StringEquals":{
               "sts:Externalid": "vmimport"
            }
         }
      }
   ]
}
EOF

cat > role-policy.json <<EOF
{
   "Version":"2012-10-17",
   "Statement":[
      {
         "Effect": "Allow",
         "Action": [
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket" 
         ],
         "Resource": [
            "arn:aws:s3:::${S3_BUCKET}",
            "arn:aws:s3:::${S3_BUCKET}/*"
         ]
      },
      {
         "Effect": "Allow",
         "Action": [
            "ec2:ModifySnapshotAttribute",
            "ec2:CopySnapshot",
            "ec2:RegisterImage",
            "ec2:Describe*"
         ],
         "Resource": "*"
      }
   ]
}
EOF

aws iam create-role --role-name vmimport --assume-role-policy-document file://trust-policy.json || true
aws iam put-role-policy --role-name vmimport --policy-name vmimport --policy-document file://role-policy.json

# 3. OVA 파일 업로드 함수
upload_vm() {
    local VM_NAME=$1
    local OVA_FILE=$2
    
    echo -e "${YELLOW}3. ${VM_NAME} OVA 파일 업로드 중...${NC}"
    aws s3 cp ${OVA_FILE} s3://${S3_BUCKET}/${VM_NAME}.ova
    
    # 4. VM Import 시작
    echo -e "${YELLOW}4. ${VM_NAME} VM Import 시작...${NC}"
    cat > ${VM_NAME}-containers.json <<EOF
{
  "Description": "${VM_NAME} VM",
  "Format": "ova",
  "UserBucket": {
      "S3Bucket": "${S3_BUCKET}",
      "S3Key": "${VM_NAME}.ova"
  }
}
EOF

    IMPORT_TASK_ID=$(aws ec2 import-image \
        --description "${VM_NAME} VM" \
        --disk-containers file://${VM_NAME}-containers.json \
        --region ${REGION} \
        --query 'ImportTaskId' \
        --output text)
    
    echo -e "${GREEN}${VM_NAME} Import Task ID: ${IMPORT_TASK_ID}${NC}"
    
    # 5. Import 진행 상황 확인
    echo -e "${YELLOW}5. ${VM_NAME} Import 진행 상황 확인 중...${NC}"
    while true; do
        STATUS=$(aws ec2 describe-import-image-tasks \
            --import-task-ids ${IMPORT_TASK_ID} \
            --region ${REGION} \
            --query 'ImportImageTasks[0].Status' \
            --output text)
        
        PROGRESS=$(aws ec2 describe-import-image-tasks \
            --import-task-ids ${IMPORT_TASK_ID} \
            --region ${REGION} \
            --query 'ImportImageTasks[0].Progress' \
            --output text)
        
        echo -e "${YELLOW}상태: ${STATUS}, 진행률: ${PROGRESS}%${NC}"
        
        if [ "$STATUS" = "completed" ]; then
            AMI_ID=$(aws ec2 describe-import-image-tasks \
                --import-task-ids ${IMPORT_TASK_ID} \
                --region ${REGION} \
                --query 'ImportImageTasks[0].ImageId' \
                --output text)
            echo -e "${GREEN}${VM_NAME} AMI 생성 완료: ${AMI_ID}${NC}"
            echo "${VM_NAME}_AMI_ID=${AMI_ID}" >> ami-ids.txt
            break
        elif [ "$STATUS" = "deleted" ] || [ "$STATUS" = "deleting" ]; then
            echo -e "${RED}${VM_NAME} Import 실패${NC}"
            break
        fi
        
        sleep 30
    done
}

# 사용법 출력
echo -e "${GREEN}=== 사용법 ===${NC}"
echo "각 VM의 OVA 파일 경로를 입력하세요:"
echo ""
echo "예시:"
echo "  ./vm-import.sh web /path/to/web.ova"
echo "  ./vm-import.sh was /path/to/was.ova"
echo "  ./vm-import.sh proxysql /path/to/proxysql.ova"
echo "  ./vm-import.sh mysql /path/to/mysql.ova"
echo ""

# 인자 확인
if [ $# -eq 2 ]; then
    upload_vm $1 $2
else
    echo -e "${RED}오류: VM 이름과 OVA 파일 경로를 입력하세요${NC}"
    echo "사용법: $0 <vm-name> <ova-file-path>"
    exit 1
fi

echo -e "${GREEN}=== 완료 ===${NC}"
echo "생성된 AMI ID는 ami-ids.txt 파일에 저장되었습니다."
echo "Terraform variables.tf 파일에 AMI ID를 업데이트하세요."
