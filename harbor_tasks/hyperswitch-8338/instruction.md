Bug: fix(analytics): refactor auth analytics to support profile,org and merchant level auth



### Feature Description

Exposed the auth analytics under profile, merchant and org levels

### Possible Implementation

Expose different endpoints for auth analytics sankey

### Have you spent some time checking if this feature request has been raised before?

- [x] I checked and didn't find a similar issue

### Have you read the Contributing Guidelines?

- [x] I have read the [Contributing Guidelines](https://github.com/juspay/hyperswitch/blob/main/docs/CONTRIBUTING.md)

### Are you willing to submit a PR?

None

DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [ ] Bugfix
- [ ] New feature
- [ ] Enhancement
- [x] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
Exposed endpoints for auth analytics under profile, merchant and org access levels.


### Additional Changes

- [ ] This PR modifies the API contract
- [ ] This PR modifies the database schema
- [ ] This PR modifies application configuration/environment variables



Here are the cURLs for the endpoint modified

```
curl 'http://localhost:8080/analytics/v1/merchant/metrics/auth_events' \
  -H 'Accept: */*' \
  -H 'Accept-Language: en-US,en;q=0.5' \
  -H 'Cache-Control: no-cache' \
  -H 'Connection: keep-alive' \
  -H 'Content-Type: application/json' \
  -b 'login_token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiY2IzYjdjNGQtYjQ0Mi00ZDk0LWJkMjQtNjk5NjI4ZjQ1MzBkIiwibWVyY2hhbnRfaWQiOiJtZXJjaGFudF8xNzQ4Mjg1ODc1Iiwicm9sZV9pZCI6Im9yZ19hZG1pbiIsImV4cCI6MTc1MDQxODczNiwib3JnX2lkIjoib3JnX1VBQnlpWmZ4TW44dFpuSnZUemlvIiwicHJvZmlsZV9pZCI6InByb19Pcjh5cmlGYzBPY1pJZHFBOVFVVyIsInRlbmFudF9pZCI6InB1YmxpYyJ9.ihLlIahjaxw1Tq8OYv0601E93UpT8TKgYoskRK6Os0M' \
  -H 'Origin: http://localhost:9000' \
  -H 'Pragma: no-cache' \
  -H 'Referer: http://localhost:9000/dashboard/analytics-authentication' \
  -H 'Sec-Fetch-Dest: empty' \
  -H 'Sec-Fetch-Mode: cors' \
  -H 'Sec-Fetch-Site: same-origin' \
  -H 'Sec-GPC: 1' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36' \
  -H 'X-Merchant-Id: merchant_1748285875' \
  -H 'X-Profile-Id: pro_Or8yriFc0OcZIdqA9QUW' \
  -H 'api-key: hyperswitch' \
  -H 'authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiY2IzYjdjNGQtYjQ0Mi00ZDk0LWJkMjQtNjk5NjI4ZjQ1MzBkIiwibWVyY2hhbnRfaWQiOiJtZXJjaGFudF8xNzQ4Mjg1ODc1Iiwicm9sZV9pZCI6Im9yZ19hZG1pbiIsImV4cCI6MTc1MDQxODczNiwib3JnX2lkIjoib3JnX1VBQnlpWmZ4TW44dFpuSnZUemlvIiwicHJvZmlsZV9pZCI6InByb19Pcjh5cmlGYzBPY1pJZHFBOVFVVyIsInRlbmFudF9pZCI6InB1YmxpYyJ9.ihLlIahjaxw1Tq8OYv0601E93UpT8TKgYoskRK6Os0M' \
  -H 'sec-ch-ua: "Brave";v="137", "Chromium";v="137", "Not/A)Brand";v="24"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "macOS"' \
  --data-raw '[{"timeRange":{"startTime":"2025-01-10T18:30:00Z","endTime":"2025-06-18T11:25:39Z"},"mode":"ORDER","source":"BATCH","metrics":["authentication_count","authentication_attempt_count","authentication_success_count","challenge_flow_count","frictionless_flow_count","frictionless_success_count","challenge_attempt_count","challenge_success_count"],"delta":true}]'
```

```
curl 'http://localhost:8080/analytics/v1/org/metrics/auth_events' \
  -H 'Accept: */*' \
  -H 'Accept-Language: en-US,en;q=0.5' \
  -H 'Cache-Control: no-cache' \
  -H 'Connection: keep-alive' \
  -H 'Content-Type: application/json' \
  -b 'login_token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiY2IzYjdjNGQtYjQ0Mi00ZDk0LWJkMjQtNjk5NjI4ZjQ1MzBkIiwibWVyY2hhbnRfaWQiOiJtZXJjaGFudF8xNzQ4Mjg1ODc1Iiwicm9sZV9pZCI6Im9yZ19hZG1pbiIsImV4cCI6MTc1MDQxODczNiwib3JnX2lkIjoib3JnX1VBQnlpWmZ4TW44dFpuSnZUemlvIiwicHJvZmlsZV9pZCI6InByb19Pcjh5cmlGYzBPY1pJZHFBOVFVVyIsInRlbmFudF9pZCI6InB1YmxpYyJ9.ihLlIahjaxw1Tq8OYv0601E93UpT8TKgYoskRK6Os0M' \
  -H 'Origin: http://localhost:9000' \
  -H 'Pragma: no-cache' \
  -H 'Referer: http://localhost:9000/dashboard/analytics-authentication' \
  -H 'Sec-Fetch-Dest: empty' \
  -H 'Sec-Fetch-Mode: cors' \
  -H 'Sec-Fetch-Site: same-origin' \
  -H 'Sec-GPC: 1' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36' \
  -H 'X-Merchant-Id: merchant_1748285875' \
  -H 'X-Profile-Id: pro_Or8yriFc0OcZIdqA9QUW' \
  -H 'api-key: hyperswitch' \
  -H 'authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiY2IzYjdjNGQtYjQ0Mi00ZDk0LWJkMjQtNjk5NjI4ZjQ1MzBkIiwibWVyY2hhbnRfaWQiOiJtZXJjaGFudF8xNzQ4Mjg1ODc1Iiwicm9sZV9pZCI6Im9yZ19hZG1pbiIsImV4cCI6MTc1MDQxODczNiwib3JnX2lkIjoib3JnX1VBQnlpWmZ4TW44dFpuSnZUemlvIiwicHJvZmlsZV9pZCI6InByb19Pcjh5cmlGYzBPY1pJZHFBOVFVVyIsInRlbmFudF9pZCI6InB1YmxpYyJ9.ihLlIahjaxw1Tq8OYv0601E93UpT8TKgYoskRK6Os0M' \
  -H 'sec-ch-ua: "Brave";v="137", "Chromium";v="137", "Not/A)Brand";v="24"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "macOS"' \
  --data-raw '[{"timeRange":{"startTi
