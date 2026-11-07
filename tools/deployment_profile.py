"""Validate noncredential endpoint profiles without logging their values."""
import ipaddress
import re
from urllib.parse import urlsplit

KEYS = {'homeURL', 'tailnetURL', 'connectOverrides', 'defaultTVHost'}
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


def private_ipv4(value):
    if not isinstance(value, str):
        raise ValueError('Expected a private IPv4 address')
    try:
        address = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        raise ValueError('Expected a private IPv4 address') from None
    if str(address) != value or not any(address in network for network in PRIVATE_NETWORKS):
        raise ValueError('Expected a private IPv4 address')
    return value


def origin(value):
    if not isinstance(value, str) or not value.isascii() or any(ord(c) <= 32 or ord(c) == 127 for c in value):
        raise ValueError('Expected a canonical HTTPS server origin')
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise ValueError('Expected a canonical HTTPS server origin') from None
    valid_host = parts.hostname and len(parts.hostname) <= 253 and all(
        re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label)
        for label in parts.hostname.split('.'))
    if (parts.scheme != 'https' or not valid_host or parts.username is not None or parts.password is not None
            or parts.path not in ('', '/') or parts.query or parts.fragment or '?' in value or '#' in value
            or port not in (None, 443, 8443)):
        raise ValueError('Expected a canonical HTTPS server origin')
    canonical = 'https://' + parts.hostname + (':8443' if port == 8443 else '')
    if value.rstrip('/') != canonical:
        raise ValueError('Expected a canonical HTTPS server origin')
    return canonical


def validate(value):
    if not isinstance(value, dict) or set(value) != KEYS:
        raise ValueError('Endpoint profile must contain only the four documented configuration fields')
    home, tailnet = origin(value['homeURL']), origin(value['tailnetURL'])
    if home == tailnet:
        raise ValueError('Home and Tailscale server origins must be distinct')
    hosts = {urlsplit(home).hostname, urlsplit(tailnet).hostname}
    overrides = value['connectOverrides']
    if not isinstance(overrides, dict) or any(key not in hosts for key in overrides):
        raise ValueError('Routing overrides must belong to configured server hostnames')
    checked = {key: private_ipv4(address) for key, address in overrides.items()}
    tv = value['defaultTVHost']
    if tv != '':
        private_ipv4(tv)
    return {'homeURL': home, 'tailnetURL': tailnet, 'connectOverrides': checked, 'defaultTVHost': tv}
