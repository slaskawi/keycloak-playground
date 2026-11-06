import json
import unittest
from unittest.mock import patch

import publisher


class PublisherTest(unittest.TestCase):
    def test_preserves_all_bundle_domain_keys(self):
        local = {"keys": [{"kid": "east-key"}]}
        bundles = {
            "west.example.test": {"keys": [{"kid": "west-key"}]},
            "third.example.test": {"keys": [{"kid": "third-key"}]},
        }

        def spire(_context, *args):
            if args == ("bundle", "show", "-format", "spiffe"):
                return json.dumps(local)
            if args == ("bundle", "list", "-output", "json"):
                return json.dumps({"bundles": [{"trust_domain": domain} for domain in bundles]})
            return json.dumps(bundles[args[3]])

        with patch.object(publisher, "spire", side_effect=spire):
            result = publisher.current_map("demo")

        self.assertEqual(result["trust_domains"], {publisher.OWN_DOMAIN: local, **bundles})

    def test_removes_domain_missing_from_next_snapshot(self):
        domains = [[{"trust_domain": "west.example.test"}], []]

        def spire(_context, *args):
            if args == ("bundle", "show", "-format", "spiffe"):
                return '{"keys":[]}'
            if args == ("bundle", "list", "-output", "json"):
                return json.dumps({"bundles": domains.pop(0)})
            return '{"keys":[{"kid":"west"}]}'

        with patch.object(publisher, "spire", side_effect=spire):
            self.assertIn("west.example.test", publisher.current_map("demo")["trust_domains"])
            self.assertEqual(set(publisher.current_map("demo")["trust_domains"]), {publisher.OWN_DOMAIN})

    def test_rejects_malformed_bundle(self):
        with patch.object(publisher, "spire", return_value='{"keys":"invalid"}'):
            with self.assertRaises(ValueError):
                publisher.current_map("demo")


if __name__ == "__main__":
    unittest.main()
