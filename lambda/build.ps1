# Lambda 함수 빌드 스크립트 (Windows PowerShell)

Write-Host "Building Lambda functions..." -ForegroundColor Green

# 임시 디렉토리 생성
New-Item -ItemType Directory -Force -Path build | Out-Null

# Health Monitor 빌드
Write-Host "Building health_monitor..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path build/health_monitor | Out-Null
Copy-Item health_monitor.py build/health_monitor/
pip install -r requirements.txt -t build/health_monitor/ --platform manylinux2014_x86_64 --only-binary=:all:
Set-Location build/health_monitor
Compress-Archive -Path * -DestinationPath ../health_monitor.zip -Force
Set-Location ../..

# Failover Controller 빌드
Write-Host "Building failover_controller..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path build/failover_controller | Out-Null
Copy-Item failover_controller.py build/failover_controller/
pip install -r requirements.txt -t build/failover_controller/ --platform manylinux2014_x86_64 --only-binary=:all:
Set-Location build/failover_controller
Compress-Archive -Path * -DestinationPath ../failover_controller.zip -Force
Set-Location ../..

# DMS Chain Starter 빌드
Write-Host "Building dms_chain_starter..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path build/dms_chain_starter | Out-Null
Copy-Item dms_chain_starter.py build/dms_chain_starter/
pip install -r requirements.txt -t build/dms_chain_starter/ --platform manylinux2014_x86_64 --only-binary=:all:
Set-Location build/dms_chain_starter
Compress-Archive -Path * -DestinationPath ../dms_chain_starter.zip -Force
Set-Location ../..

# ZIP 파일 이동
Move-Item build/health_monitor.zip . -Force
Move-Item build/failover_controller.zip . -Force
Move-Item build/dms_chain_starter.zip . -Force

# 정리
Remove-Item -Recurse -Force build

Write-Host "Build completed!" -ForegroundColor Green
Write-Host "Created:" -ForegroundColor Cyan
Write-Host "  - health_monitor.zip"
Write-Host "  - failover_controller.zip"
Write-Host "  - dms_chain_starter.zip"
