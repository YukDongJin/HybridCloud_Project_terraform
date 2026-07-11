# 도메인 설정 가이드

## 개요

`youk.cloud` 도메인을 사용하여 `failover.youk.cloud`로 접속할 수 있도록 설정합니다.

## 1단계: Route53 Hosted Zone 생성 (Terraform 자동)

Terraform이 자동으로 생성하지만, 수동으로 먼저 만들 수도 있습니다:

### AWS Console에서 생성
1. AWS Console → Route53
2. Hosted zones → Create hosted zone
3. Domain name: `youk.cloud`
4. Type: Public hosted zone
5. Create hosted zone

### NS 레코드 확인
생성 후 NS 레코드 4개가 표시됩니다:
```
ns-xxxx.awsdns-xx.org
ns-xxxx.awsdns-xx.com
ns-xxxx.awsdns-xx.net
ns-xxxx.awsdns-xx.co.uk
```

## 2단계: 가비아 네임서버 변경

### 가비아 관리 페이지
1. https://my.gabia.com 로그인
2. **서비스 관리 → 도메인 관리**
3. **youk.cloud 선택 → 관리 도구**
4. **네임서버 설정 → 네임서버 변경**

### 네임서버 입력
**기본 네임서버 → 다른 네임서버 사용** 선택 후:

```
1차 네임서버: ns-xxxx.awsdns-xx.org
2차 네임서버: ns-xxxx.awsdns-xx.com
3차 네임서버: ns-xxxx.awsdns-xx.net
4차 네임서버: ns-xxxx.awsdns-xx.co.uk
```

**주의**: Route53에서 확인한 실제 NS 레코드로 입력하세요!

### 저장 및 대기
- 저장 후 **최대 48시간** 소요 (보통 1-2시간)
- 전파 확인: https://www.whatsmydns.net/

## 3단계: Terraform 실행

```bash
cd infrastructure/terraform

# terraform.tfvars 확인
cat terraform.tfvars

# 도메인 설정이 있는지 확인
# enable_domain = true
# domain_name   = "youk.cloud"
# subdomain     = "failover"

# Terraform 실행
terraform init
terraform plan
terraform apply
```

## 4단계: DNS 전파 확인

### 명령어로 확인
```bash
# NS 레코드 확인
nslookup -type=NS youk.cloud

# A 레코드 확인 (ALB 연결)
nslookup failover.youk.cloud

# 또는 dig 사용
dig youk.cloud NS
dig failover.youk.cloud A
```

### 브라우저에서 확인
```
http://failover.youk.cloud
```

## 5단계: HTTPS 설정 (ACM 인증서)

Terraform이 자동으로 ACM 인증서를 발급하고 ALB에 연결합니다.

### 인증서 확인
```bash
# ACM 인증서 목록
aws acm list-certificates --region ap-northeast-2

# 인증서 상태 확인
aws acm describe-certificate --certificate-arn <CERT_ARN> --region ap-northeast-2
```

### HTTPS 접속
인증서 발급 완료 후 (약 5-10분):
```
https://failover.youk.cloud
```

## 문제 해결

### NS 레코드가 전파되지 않음
```bash
# 현재 NS 레코드 확인
nslookup -type=NS youk.cloud 8.8.8.8

# 가비아 NS 레코드 확인
nslookup -type=NS youk.cloud
```

가비아에서 설정한 NS 레코드가 맞는지 확인하세요.

### ACM 인증서 발급 실패
Route53 DNS 검증 레코드가 자동으로 생성되지만, 실패 시:

1. Route53 → Hosted zones → youk.cloud
2. `_acm-challenge` 레코드가 있는지 확인
3. 없으면 Terraform 재실행: `terraform apply`

### ALB에 HTTPS 리스너가 없음
ALB 모듈에 HTTPS 리스너를 추가해야 합니다 (아래 참고).

## ALB HTTPS 리스너 추가 (선택사항)

현재는 HTTP만 지원합니다. HTTPS를 추가하려면:

### modules/alb/main.tf 수정
```hcl
# HTTPS 리스너 추가
resource "aws_lb_listener" "https" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# HTTP → HTTPS 리다이렉트
resource "aws_lb_listener" "http_redirect" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

## 비용

- **Route53 Hosted Zone**: $0.50/월
- **Route53 쿼리**: $0.40/백만 쿼리 (거의 무료)
- **ACM 인증서**: 무료
- **총**: 약 $0.50/월

## 요약

1. ✅ Route53 Hosted Zone 생성 (Terraform 자동)
2. ✅ 가비아에서 NS 레코드 변경 (수동)
3. ✅ DNS 전파 대기 (1-2시간)
4. ✅ Terraform apply (도메인 연결)
5. ✅ ACM 인증서 발급 (Terraform 자동)
6. ✅ `failover.youk.cloud`로 접속

**최종 URL**: `http://failover.youk.cloud` (HTTPS는 선택사항)
