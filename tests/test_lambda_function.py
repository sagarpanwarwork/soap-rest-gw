"""Small unit tests for the SOAP parsing and Mustache/JSON boundary.

Install src/requirements.txt before running: python -m unittest discover -s tests
"""

import os
import sys
import unittest

os.environ.setdefault("MAPPING_TABLE_NAME", "unit-test-mappings")
os.environ.setdefault("THIRD_PARTY_API_URL", "https://dummyjson.com/users/add")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "src"))

import lambda_function  # noqa: E402


VALID_XML = b'''<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <CreateUserRequest xmlns="urn:zeron:users:v1">
      <FirstName>Ana "quoted" &amp; Friends</FirstName>
      <LastName>O'Neil</LastName>
      <Age>28</Age>
    </CreateUserRequest>
  </soap:Body>
</soap:Envelope>'''


class LambdaFunctionUnitTests(unittest.TestCase):
    def test_parse_soap_request(self):
        user = lambda_function._parse_soap_request(VALID_XML)
        self.assertEqual(user["firstName"], 'Ana "quoted" & Friends')
        self.assertEqual(user["lastName"], "O'Neil")
        self.assertEqual(user["age"], 28)

    def test_json_template_handles_quotes_and_xml_characters(self):
        mapping = {
            "request_template": (
                '{"firstName":"{{{firstNameJson}}}",'
                '"lastName":"{{{lastNameJson}}}",'
                '"age":{{{ageJson}}}}'
            )
        }
        user = {"firstName": 'Ana "Q" & <x>', "lastName": "O'Neil", "age": 28}
        payload = lambda_function._render_request_payload(mapping, user)
        self.assertEqual(payload["firstName"], 'Ana "Q" & <x>')
        self.assertEqual(payload["lastName"], "O'Neil")
        self.assertEqual(payload["age"], 28)

    def test_rejects_external_entity_doctype(self):
        malicious = b'''<!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body><CreateUserRequest><FirstName>&xxe;</FirstName></CreateUserRequest></soap:Body>
        </soap:Envelope>'''
        with self.assertRaises(Exception):
            lambda_function._parse_soap_request(malicious)

    def test_missing_field_is_rejected(self):
        invalid = b'''<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body><CreateUserRequest><FirstName>Ana</FirstName><Age>28</Age></CreateUserRequest></soap:Body>
        </soap:Envelope>'''
        with self.assertRaises(ValueError):
            lambda_function._parse_soap_request(invalid)


if __name__ == "__main__":
    unittest.main()
