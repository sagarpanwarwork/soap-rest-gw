"""SOAP 1.1 to REST/JSON adapter for the Zeron Academy lab.

The function deliberately supports one operation (CreateUser) so students can
focus on integration patterns rather than a large SOAP framework.
"""

from __future__ import annotations

import base64										# Decode API Gateway's Base64-encoded request bodies
import binascii
import json 										# Parse and generate JSON data
import logging 										# Write application logs to CloudWatch
import os											# Read Lambda environment variables
import urllib.error									# Handle HTTP and connection errors
import urllib.request								# Make HTTPS requests to the third-party API
from html import escape								# Escape text inserted into a SOAP Fault
from typing import Any

import boto3										# Access DynamoDB
import pystache										# Render Mustache templates
from defusedxml import ElementTree as SafeET		# Parse XML with protections against common XML entity attacks
from defusedxml.common import DefusedXmlException	# 


# Configurations
LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb") 												# creates a reusable DynamoDB resource client.
TABLE_NAME = os.environ["MAPPING_TABLE_NAME"]										# identifies the DynamoDB mapping table.
MAPPING_ID = os.environ.get("MAPPING_ID", "CreateUser#v1")							# identifies which mapping record to retrieve. Its default is CreateUser#v1
THIRD_PARTY_API_URL = os.environ["THIRD_PARTY_API_URL"]								# identifies the REST endpoint.
MAX_XML_BYTES = int(os.environ.get("MAX_XML_BYTES", "65536"))						# limits the request body size to 65,536 bytes by default.
UPSTREAM_TIMEOUT_SECONDS = float(os.environ.get("UPSTREAM_TIMEOUT_SECONDS", "5"))	# limits how long the HTTP client waits for the downstream service, set to five seconds by default.
SOAP_ENVELOPE_NS = "http://schemas.xmlsoap.org/soap/envelope/"
SOAP_CONTENT_TYPE = "text/xml; charset=utf-8"

# This function formats Lambda's response for API Gateway Lambda proxy integration.
def _response(status_code: int, body: str) -> dict[str, Any]:
    """Return the response format expected by API Gateway Lambda proxy integration."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": SOAP_CONTENT_TYPE,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
        "body": body,
        "isBase64Encoded": False,
    }


def _soap_fault(status_code: int, fault_code: str, message: str) -> dict[str, Any]:
    """Build a SOAP 1.1 Fault without reflecting raw XML or upstream errors."""
    safe_message = escape(message)
    safe_fault_code = escape(fault_code)
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="{SOAP_ENVELOPE_NS}">
  <soap:Body>
    <soap:Fault>
      <faultcode>soap:{safe_fault_code}</faultcode>
      <faultstring>{safe_message}</faultstring>
    </soap:Fault>
  </soap:Body>
</soap:Envelope>'''
    return _response(status_code, body)


def _local_name(tag: str) -> str:
    """Return an XML element's local name, ignoring its namespace prefix/URI."""
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag.split(":", 1)[-1]


def _direct_child_text(parent: Any, wanted_name: str) -> str | None:
    """Find a direct child by local name. Reject nested markup in simple fields."""
    matches = [child for child in list(parent) if _local_name(child.tag) == wanted_name]
    if len(matches) != 1:
        return None
    child = matches[0]
    if list(child):
        raise ValueError(f"{wanted_name} must contain text only")
    return (child.text or "").strip()


def _parse_soap_request(xml_bytes: bytes) -> dict[str, Any]:
    """Parse and validate the small SOAP contract used by this training project."""
    root = SafeET.fromstring(xml_bytes)
    if root.tag != f"{{{SOAP_ENVELOPE_NS}}}Envelope":
        raise ValueError("Expected a SOAP 1.1 Envelope")

    body_element = next(
        (child for child in list(root) if child.tag == f"{{{SOAP_ENVELOPE_NS}}}Body"), None
    )
    if body_element is None:
        raise ValueError("SOAP Body is required")

    operations = list(body_element)
    if len(operations) != 1 or _local_name(operations[0].tag) != "CreateUserRequest":
        raise ValueError("Only the CreateUserRequest operation is supported")

    operation = operations[0]
    first_name = _direct_child_text(operation, "FirstName")
    last_name = _direct_child_text(operation, "LastName")
    age_text = _direct_child_text(operation, "Age")

    if not first_name or not first_name.strip():
        raise ValueError("FirstName is required")
    if not last_name or not last_name.strip():
        raise ValueError("LastName is required")
    if len(first_name) > 80 or len(last_name) > 80:
        raise ValueError("FirstName and LastName must be 80 characters or fewer")
    if age_text is None:
        raise ValueError("Age is required")

    try:
        age = int(age_text)
    except ValueError as exc:
        raise ValueError("Age must be an integer") from exc
    if not 1 <= age <= 120:
        raise ValueError("Age must be between 1 and 120")

    return {"firstName": first_name, "lastName": last_name, "age": age}


def _load_mapping() -> dict[str, Any]:
    table = DYNAMODB.Table(TABLE_NAME)
    result = table.get_item(Key={"mapping_id": MAPPING_ID}, ConsistentRead=True)
    item = result.get("Item")
    if not item:
        raise RuntimeError("Required mapping configuration was not found")
    for field in ("request_template", "response_template"):
        if not item.get(field):
            raise RuntimeError(f"Mapping configuration is missing {field}")
    return item


def _json_string_contents(value: str) -> str:
    """Return safely JSON-escaped string contents, without the surrounding quotes.

    The request Mustache template uses triple-brace placeholders for these
    pre-escaped values. The rendered result is parsed by json.loads before use.
    """
    return json.dumps(value, ensure_ascii=False)[1:-1]


def _render_request_payload(mapping: dict[str, Any], user: dict[str, Any]) -> dict[str, Any]:
    context = {
        "firstNameJson": _json_string_contents(user["firstName"]),
        "lastNameJson": _json_string_contents(user["lastName"]),
        "ageJson": str(user["age"]),
    }
    rendered = pystache.render(mapping["request_template"], context)
    payload = json.loads(rendered)

    # Enforce the intended outbound contract even if a template is edited wrongly.
    if set(payload.keys()) != {"firstName", "lastName", "age"}:
        raise ValueError("Request mapping generated an unexpected JSON schema")
    if not isinstance(payload["firstName"], str) or not isinstance(payload["lastName"], str):
        raise ValueError("Request mapping generated invalid name fields")
    if not isinstance(payload["age"], int):
        raise ValueError("Request mapping generated an invalid age")
    return payload


def _call_third_party(payload: dict[str, Any]) -> dict[str, Any]:
    """Call the configured HTTPS mock API with a short timeout."""
    request = urllib.request.Request(
        THIRD_PARTY_API_URL,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "Zeron-SOAP-REST-Gateway/1.0",},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT_SECONDS) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError(f"Upstream returned HTTP {response.status}")
        raw_body = response.read(256 * 1024 + 1)
        if len(raw_body) > 256 * 1024:
            raise RuntimeError("Upstream response exceeded the permitted size")
        parsed = json.loads(raw_body.decode("utf-8"))

    if not isinstance(parsed, dict):
        raise RuntimeError("Upstream response did not match the expected JSON contract")
    if not isinstance(parsed.get("id"), int):
        raise RuntimeError("Upstream response contained an invalid id")
    if not isinstance(parsed.get("firstName"), str) or not isinstance(parsed.get("lastName"), str):
        raise RuntimeError("Upstream response contained invalid name fields")
    if not isinstance(parsed.get("age"), int):
        raise RuntimeError("Upstream response contained an invalid age")
    return parsed


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Handle one SOAP request and return one SOAP response."""
    headers = {str(key).lower(): value for key, value in (event.get("headers") or {}).items()}
    content_type = str(headers.get("content-type", "")).lower()
    if not content_type.startswith("text/xml"):
        return _soap_fault(415, "Client", "Content-Type must be text/xml for this SOAP 1.1 lab")

    body = event.get("body")
    if not isinstance(body, str) or not body:
        return _soap_fault(400, "Client", "A non-empty SOAP request body is required")

    try:
        if event.get("isBase64Encoded"):
            xml_bytes = base64.b64decode(body, validate=True)
        else:
            xml_bytes = body.encode("utf-8")
    except (binascii.Error, UnicodeEncodeError):
        return _soap_fault(400, "Client", "The request body is not valid encoded XML")

    if len(xml_bytes) > MAX_XML_BYTES:
        return _soap_fault(413, "Client", "SOAP request exceeds the permitted size")

    try:
        user = _parse_soap_request(xml_bytes)
    except (ValueError, SafeET.ParseError, DefusedXmlException):
        LOGGER.warning("Invalid SOAP request; requestId=%s", context.aws_request_id)
        return _soap_fault(400, "Client", "The SOAP request is invalid or unsupported")

    try:
        mapping = _load_mapping()
        outbound_payload = _render_request_payload(mapping, user)
        upstream_response = _call_third_party(outbound_payload)
        response_xml = pystache.render(mapping["response_template"], upstream_response).strip()
        LOGGER.info(json.dumps({
            "event": "soap_adapter_success",
            "requestId": context.aws_request_id,
            "operation": "CreateUser",
            "upstreamStatus": "success",
        }))
        return _response(200, response_xml)
    except TimeoutError:
        LOGGER.warning("Upstream timeout; requestId=%s", context.aws_request_id)
        return _soap_fault(504, "Server", "The downstream service timed out")
    except urllib.error.HTTPError as exc:
        upstream_body = exc.read(2048).decode("utf-8", errors="replace")
        LOGGER.warning(
			"Upstream HTTP error; requestId=%s; status=%s; "
			"server=%s; body=%s",
			context.aws_request_id,
			exc.code,
			exc.headers.get("Server", "unknown"),
			upstream_body[:1000],
		)
        return _soap_fault(502, "Server", "The downstream service returned an error")
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            LOGGER.warning("Upstream timeout; requestId=%s", context.aws_request_id)
            return _soap_fault(504, "Server", "The downstream service timed out")
        LOGGER.warning("Upstream connection error; requestId=%s; reason=%s", context.aws_request_id, type(exc.reason).__name__)
        return _soap_fault(502, "Server", "The downstream service could not be reached")
    except Exception:
        # Do not log the full request body or sensitive values.
        LOGGER.exception("SOAP adapter failed; requestId=%s", context.aws_request_id)
        return _soap_fault(500, "Server", "The request could not be processed")
