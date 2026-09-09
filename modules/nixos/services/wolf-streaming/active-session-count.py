import json
import socket
import sys

connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.settimeout(2)
connection.connect(sys.argv[1])
connection.sendall(
    b"GET /api/v1/sessions HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n\r\n"
)
response = bytearray()
while chunk := connection.recv(65536):
    response.extend(chunk)
body = bytes(response).split(b"\r\n\r\n", 1)[1]
print(len(json.loads(body).get("sessions", [])))
