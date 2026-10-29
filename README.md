# Zeron Academy — Serverless SOAP-to-REST Integration Gateway

A teaching project that adapts a legacy SOAP 1.1/XML request to a JSON REST API and transforms the returned JSON into a SOAP/XML response. The infrastructure is managed by Terraform and split into independent `dev` and `prod` roots.

> **Scope warning:** this is a training integration. The downstream API is DummyJSON, whose `POST /users/add` endpoint simulates creation and does not persist a user. The `prod` folder demonstrates a more production-oriented configuration (IAM/SigV4 authorization, longer log retention, DynamoDB PITR and deletion protection); it is not a production-ready business service while it uses a public mock API.

## 1. Architecture and the VPC decision

```text
Legacy client -- SOAP/XML over HTTPS --> AWS WAF --> API Gateway REST API
                                                       |
                                                       v
                                               Lambda SOAP adapter
                                                |             |
                                                |             +--> HTTPS POST JSON --> DummyJSON
                                                |
                                                +--> DynamoDB GetItem (mapping templates)
                                                       |
Client <-- SOAP/XML response <--- API Gateway <-- Lambda renders SOAP template <-- JSON response
```

**This project deliberately does not create a VPC.** The Lambda function calls a public HTTPS endpoint and the regional DynamoDB API; it does not need to reach a private database, private endpoint, or internal service. Lambda functions that are not attached to a customer VPC have public internet connectivity by default. Attaching Lambda to a VPC without a suitable egress design can make the public third-party call fail and add NAT/endpoints/networking cost. See the [Lambda VPC networking documentation](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html).

Use a VPC in a later version if the function must call a private RDS database/internal service, or if a vendor requires a stable outbound IP (which typically needs a VPC egress/NAT design). Do not create a VPC merely because this is an AWS project.

### Security boundaries

- API Gateway is a Regional **REST API** because AWS WAF supports API Gateway REST API stages. A WAF web ACL is associated with each environment's API stage.
- WAF's default action is **BLOCK**. Only the configured public IPv4 CIDRs are allowed; a rate-based rule blocks allowlisted IPs that exceed the configured threshold.
- The `dev` endpoint uses `authorization = "NONE"` only to make the signed-request lab approachable; WAF still restricts it to allowlisted IPs.
- The `prod` profile adds `AWS_IAM` authorization, which means clients must sign requests with AWS Signature Version 4 and have `execute-api:Invoke` permission. IP allowlisting is not a substitute for identity authentication.
- The Lambda role can write its own logs and read one DynamoDB mapping table. It has no administrator policy and no permissions to mutate mappings.
- The SOAP parser uses `defusedxml`, limits request size, validates fields, and does not log complete user payloads. Templates are controlled infrastructure configuration, not caller-supplied text.
- DummyJSON requires no API credential. For a real vendor that requires a token, store it in Secrets Manager and grant `secretsmanager:GetSecretValue` only for that secret; do not put secrets in Terraform variables, template files, or environment values.

## 2. Repository layout

```text
soap-rest-gateway/
├── README.md
├── src/
│   ├── lambda_function.py       # SOAP parsing, JSON call, SOAP response
│   └── requirements.txt         # pinned Lambda dependencies
├── tests/
│   ├── sample-request.xml       # known-good SOAP 1.1 example
│   └── test_lambda_function.py  # basic unit tests
├── scripts/
│   ├── package.ps1              # Windows Lambda packager
│   └── package.sh               # macOS/Linux Lambda packager
└── infra/
    ├── bootstrap-state/         # one-time secure S3 backend bucket (local bootstrap state)
    ├── modules/soap-rest-gateway/ # reusable API/Lambda/DynamoDB/WAF module
    └── envs/
        ├── dev/                 # independent state and lower test limits
        └── prod/                # independent state and stronger safeguards
```

## 3. Prerequisites

- An AWS account and credentials configured with the AWS CLI. For this classroom project, the learner's identity needs permission to create the resources in the plan, including IAM roles/policies, Lambda, API Gateway, DynamoDB, WAF, CloudWatch and an S3 state bucket. In real environments, use a scoped deployment role rather than permanent administrator access.
- Terraform CLI **1.10 or newer**. The S3 backend uses native S3 lock files (`use_lockfile = true`).
- Python 3.13 and `pip` for building/testing the Lambda package.
- PowerShell on Windows, or Bash on macOS/Linux.
- A stable public IPv4 egress address for each test client/network. If your laptop is behind a school/company NAT, WAF sees the network's public egress IP, not your laptop's private address.
- AWS Region `ap-south-1` (Mumbai) for this course.

Check identity and region before doing anything:

```powershell
aws sts get-caller-identity
aws configure get region
```

The API endpoints in this repo default to `ap-south-1`, regardless of the CLI's default Region.

## 4. Create the Lambda deployment ZIP

We keep application code separate from Terraform. Terraform deploys a ZIP built by a packaging script; it does not embed Python source into HCL.

From the repository root:

```powershell
.\scripts\package.ps1
```

On macOS/Linux:

```bash
./scripts/package.sh
```

The output is `build/lambda_function.zip`. Inspect the archive: `lambda_function.py`, `defusedxml/`, and `pystache/` must be at the ZIP root, not nested inside a second project directory. Re-run the packager each time Python code or dependencies change.

Install the same dependencies locally and run the unit tests, if desired:

```powershell
python -m pip install -r .\src\requirements.txt
python -m unittest discover -s .\tests
```

## 5. Bootstrap the Terraform remote-state bucket (one time)

The environment roots use separate S3 state keys for `dev` and `prod`, with S3 lock files. The bootstrap project itself starts with local state because a state bucket cannot be managed through a backend that does not exist yet. Keep and back up `infra/bootstrap-state/terraform.tfstate` securely (it is excluded from Git); do not delete the state bucket. If the derived bucket name is already taken, change the `local.state_bucket_name` prefix before applying.

```powershell
Set-Location .\infra\bootstrap-state
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
terraform output -raw state_bucket_name
```

Record the output bucket name. This bucket has versioning, server-side encryption, and all public access blocked. It also has Terraform `prevent_destroy` enabled.

## 6. Configure and deploy DEV

Open a new PowerShell terminal at the repository root. Copy the sample files:

```powershell
Copy-Item .\infra\envs\dev\backend.hcl.example .\infra\envs\dev\backend.hcl
Copy-Item .\infra\envs\dev\terraform.tfvars.example .\infra\envs\dev\terraform.tfvars
```

Edit `infra/envs/dev/backend.hcl` and replace `REPLACE_WITH_TERRAFORM_STATE_BUCKET` with the bucket name from Step 5. Keep the `key` as `zeron-soap-gateway/dev/terraform.tfstate`.

Discover your public egress IP:

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

Edit `infra/envs/dev/terraform.tfvars` and replace the reserved sample address `203.0.113.10/32` with your actual public egress address plus `/32`, for example `198.51.100.25/32` **only if that were genuinely your public address**. The two example address ranges are documentation-only; do not leave the sample address in place. Add one CIDR per approved office/home/classroom egress range. Never use `0.0.0.0/0`.

Build the ZIP from the repository root before applying:

```powershell
.\scripts\package.ps1
```

Initialize and validate the dev root:

```powershell
Set-Location .\infra\envs\dev
terraform init -backend-config=".\backend.hcl"
terraform fmt -recursive
terraform validate
terraform plan
```

Review the plan. Expected resources include one API Gateway REST API/stage/route, one Lambda function and execution role, one DynamoDB mapping table/item, a CloudWatch log group, one WAF IP set/web ACL/association, and the Lambda invocation permission. No VPC, NAT Gateway, EC2, RDS, or public IP resource should be created.

Apply only after checking the plan and WAF CIDR:

```powershell
terraform apply
terraform output -raw api_url
```

## 7. Test the SOAP endpoint in DEV

From `infra/envs/dev`, capture the endpoint and send the sample request:

```powershell
$apiUrl = terraform output -raw api_url
curl.exe -i -X POST $apiUrl `
  -H "Content-Type: text/xml; charset=utf-8" `
  --data-binary "@..\..\..\tests\sample-request.xml"
```

The body is a SOAP 1.1 `CreateUserRequest`. Lambda validates it, reads `CreateUser#v1` from DynamoDB, renders a JSON request template, calls `https://dummyjson.com/users/add`, renders the response template, and returns SOAP XML with HTTP 200. DummyJSON simulates the create and does not persist the user.

Expected response shape (the returned `UserId` is generated by DummyJSON and may differ):

```xml
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <CreateUserResponse xmlns="urn:zeron:users:v1">
      <User>
        <UserId>...</UserId>
        <FirstName>Ajmal</FirstName>
        <LastName>Student</LastName>
        <Age>29</Age>
      </User>
    </CreateUserResponse>
  </soap:Body>
</soap:Envelope>
```

### Negative tests

- Send from an IP not in the WAF IP set: expect WAF to block the request (typically HTTP 403).
- Remove a required XML element or send malformed XML: expect HTTP 400 with a SOAP Fault.
- Send JSON instead of XML or omit `Content-Type: text/xml`: expect HTTP 415.
- Use `Age=999`: expect HTTP 400.
- Exceed the 64 KiB application XML limit: expect HTTP 413.
- Temporarily use an invalid upstream URL in a disposable dev test to observe a controlled SOAP Fault (restore the value immediately). Do not change production configuration for this test.

If you get a WAF 403, confirm the source public egress IP in `terraform.tfvars`, re-run `terraform plan`, then `terraform apply`. A laptop switching from Wi-Fi to a hotspot often changes the source IP.

## 8. Verify AWS resources and logs

- **API Gateway:** open the REST API in the console and verify stage `dev`, route `POST /soap`, and Lambda proxy integration.
- **WAF:** open the Regional web ACL and confirm the approved IP set, default BLOCK action, rate-based rule, and association to the `dev` stage.
- **DynamoDB:** open the environment mapping table; item key should be `CreateUser#v1`. Inspect the `request_template` and `response_template` string attributes.
- **Lambda logs:** CloudWatch Logs → `/aws/lambda/zeron-soap-dev-adapter`. Successful requests log a request ID and operation, not the full SOAP payload. Invalid input logs a compact warning.
- **Metrics:** API Gateway method metrics are enabled. The WAF rules emit CloudWatch metrics. Lambda timeout/error/concurrency metrics are available through CloudWatch.

## 9. How mapping templates work

The `CreateUser#v1` item is seeded by Terraform. Its request template uses pre-JSON-escaped values (`firstNameJson`, `lastNameJson`, `ageJson`) and triple Mustache braces. The code then parses the rendered output with `json.loads()` and checks its schema before sending it. This avoids treating raw XML text as JSON syntax.

The response template uses normal double Mustache placeholders, which HTML/XML-escape returned values. Keep templates reviewed and versioned as configuration. Do not let API callers submit templates. When changing a mapping, update the Terraform-managed item and test values containing `&`, `<`, `>`, single/double quotes, missing fields, and Unicode characters. For more operations, use distinct mapping IDs such as `GetUser#v1` and `CreateUser#v2`, with explicit operation routing and schemas rather than silently changing an existing contract.

## 10. DEV versus PROD

Both roots call the same module, but keep separate Terraform states, API Gateway APIs/stages, Lambda functions, WAF ACLs, and DynamoDB tables.

| Control | Dev profile | Prod profile |
|---|---|---|
| API Gateway authorization | `NONE` plus WAF IP allowlist | `AWS_IAM` (SigV4) plus WAF IP allowlist |
| WAF rate threshold | 300 requests per five-minute evaluation window per source IP | 1,000 requests per five-minute evaluation window per source IP |
| API throttling | 5 requests/sec, burst 10 | 20 requests/sec, burst 40 |
| Lambda reserved concurrency | 2 | 10 |
| Lambda memory | 256 MB | 512 MB |
| Lambda log retention | 3 days | 30 days |
| DynamoDB point-in-time recovery | Off | On |
| DynamoDB deletion protection | Off | On |
| Terraform state | S3 key ending `/dev/terraform.tfstate` | S3 key ending `/prod/terraform.tfstate` |

The API Gateway throttling controls are **best effort**, not guaranteed spending caps. WAF blocks unapproved source IPs before the request reaches Lambda. `AWS_IAM` means the caller also needs an IAM identity policy that allows `execute-api:Invoke` and must sign each request using SigV4. For a production caller, test from an approved IP using a client configured with AWS Signature (for example, Postman AWS Signature with service `execute-api` and Region `ap-south-1`). Do not switch production authorization to `NONE` just to simplify testing.

### Configure and deploy PROD only when ready

Repeat the dev process using `infra/envs/prod/backend.hcl.example` and `terraform.tfvars.example`; use the **same state bucket** but the unique key `zeron-soap-gateway/prod/terraform.tfstate`. Set the correct production public egress CIDRs and IAM-authorized caller roles. Run `terraform plan` carefully. Keep the `prod` profile undeployed if you do not need a second WAF ACL yet.

**Important:** do not treat the `prod` profile as a real customer production service until the dummy endpoint is replaced by a contracted/owned downstream, authentication/authorization is reviewed, request and response schemas are agreed, alarm/alert ownership is defined, and release/rollback procedures are tested. The mock API is for learning only.

## 11. Load testing safely and managing cost

1. Start with manual requests (5–10 requests) and then a low, short request rate against **dev only**.
2. Keep the dev API Gateway throttle at 5 requests/sec, burst 10; keep Lambda reserved concurrency at 2; WAF limit is 300 requests per five-minute window per approved IP. Adjust only for a planned experiment.
3. Use a mock backend you control for sustained load or latency experiments. Do not load-test a public third-party dummy API; its throttling and latency are outside your control.
4. Watch API Gateway 4xx/5xx/latency, Lambda Duration/Errors/Throttles/ConcurrentExecutions, DynamoDB read usage, and WAF metrics.
5. Put an AWS Budget alert in place before the lesson. A budget alert is not an instant hard cap.
6. Re-check current regional rates in the [AWS API Gateway pricing page](https://aws.amazon.com/api-gateway/pricing/), [AWS WAF pricing page](https://aws.amazon.com/waf/pricing/), [Lambda pricing](https://aws.amazon.com/lambda/pricing/), and [DynamoDB pricing](https://aws.amazon.com/dynamodb/pricing/). WAF has recurring web ACL/rule charges even at low request volume. Two separately deployed environments each create a WAF ACL; use only dev while teaching if you want to reduce the fixed cost. The published WAF examples show charges by ACL, rule, and request; verify today's Mumbai pricing rather than treating an example as a quote.

For a rough budgeting discussion, AWS's published WAF pricing examples show a web ACL charge of about US$5/month, US$1/month per rule, and US$0.60 per million requests. With the two custom WAF rules in this design, that example would be about US$7/month per ACL before request charges; two separately deployed environments would therefore be about US$14/month before request charges, assuming those example rates apply to the account/Region. AWS's API Gateway pricing examples list Regional REST API calls at US$3.50 per million in the Mumbai example. These are planning examples, not a quote; rates, taxes, tiers, and regional details can change. Recheck the linked AWS Pricing pages and Calculator before applying.

Other cost drivers include API Gateway data transfer, Lambda duration and concurrency, DynamoDB storage/reads, and CloudWatch log ingestion/storage. DynamoDB on-demand bills reads/writes rather than idle provisioned capacity, but the table still has storage charges. Log retention is limited to avoid indefinite log accumulation.

## 12. Cleanup

Destroy each environment from its own directory after checking the plan. Start with `prod` only if you actually deployed it, then `dev`:

```powershell
# From infra/envs/dev
terraform plan -destroy
terraform destroy
```

If prod was deployed:

```powershell
# From infra/envs/prod
terraform plan -destroy
terraform destroy
```

The production-profile DynamoDB table has deletion protection enabled. To destroy that environment intentionally, first disable `enable_deletion_protection` in `terraform.tfvars`, run `terraform apply` to update the table, then run `terraform destroy`. Do not destroy the state bucket as part of routine cleanup; it stores Terraform state and is protected by `prevent_destroy`.

After cleanup, verify no API Gateway REST APIs/stages, WAF web ACLs/IP sets, Lambda functions, DynamoDB tables, or dedicated CloudWatch log groups from the lab remain. Keep the remote state bucket if you plan to reuse the course environment.

## 13. Troubleshooting map

| Symptom | Likely cause and check |
|---|---|
| WAF 403 | Client egress IP is missing from the IP set, or its rate rule blocked it. Check WAF sampled requests and `allowed_client_cidrs`. |
| API Gateway 500 | Lambda returned a malformed proxy response or failed unexpectedly. Check Lambda logs and handler deployment package. |
| API Gateway 502 | Downstream connection/HTTP error or invalid upstream response. Confirm DummyJSON availability and function logs. |
| API Gateway 504 | Downstream call timed out. The lab's upstream timeout is 5 seconds; investigate the public API and network. |
| Lambda import error | ZIP is missing `pystache` or `defusedxml`, or the package has a nested directory. Re-run `scripts/package.ps1` and inspect ZIP root. |
| Mapping not found | Check DynamoDB contains `mapping_id = CreateUser#v1`, function's `MAPPING_TABLE_NAME`, and the execution role's scoped `dynamodb:GetItem` permission. |
| `terraform init` fails | Check bucket name in `backend.hcl`, AWS identity, region, S3 permissions, and that the bootstrap completed. |
| Dev API returns 403 after changing Wi-Fi | Public egress IP changed. Update `allowed_client_cidrs`, run plan, and apply. |

## 14. Official references

- [DummyJSON Users API](https://dummyjson.com/docs/users) — fake `POST /users/add` response; the mock does not persist the user.
- [AWS Lambda VPC networking](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html) — when VPC attachment is and is not required.
- [Protect API Gateway REST APIs with AWS WAF](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-aws-waf.html).
- [AWS WAF IP sets](https://docs.aws.amazon.com/waf/latest/APIReference/API_IPSet.html).
- [Terraform `aws_api_gateway_deployment`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_deployment) — API deployment triggers and `create_before_destroy`.
- [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/), [WAF pricing](https://aws.amazon.com/waf/pricing/), [DynamoDB pricing](https://aws.amazon.com/dynamodb/pricing/).
