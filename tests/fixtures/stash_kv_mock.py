#!/usr/bin/env python3
"""sigil-stash-kv のモックサーバー（ADR 0059 バイナリプロトコル）。
使い方: stash_kv_mock.py PORT [LOG_FILE]
"""
import socket
import struct
import sys
import threading
import time

PORT = int(sys.argv[1])
LOG_FILE = sys.argv[2] if len(sys.argv) > 2 else None

store = {}  # key_bytes -> (val_bytes, expire_time)
lock = threading.Lock()


def log_event(ev):
    if LOG_FILE:
        with open(LOG_FILE, "a") as f:
            f.write(ev + "\n")


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def handle_client(sock):
    try:
        while True:
            header = read_exact(sock, 4)
            if not header:
                break
            (frame_len,) = struct.unpack(">I", header)
            if frame_len < 2 or frame_len > 4096:
                break
            payload = read_exact(sock, frame_len)
            if not payload or len(payload) != frame_len:
                break

            ver = payload[0]
            op = payload[1]
            if ver != 1:
                break

            now = time.time()
            if op == 2:  # GET
                if len(payload) < 4:
                    break
                (key_len,) = struct.unpack(">H", payload[2:4])
                if len(payload) < 4 + key_len:
                    break
                key = payload[4 : 4 + key_len]
                log_event(f"GET {key.decode(errors='replace')}")

                with lock:
                    item = store.get(key)
                    if item is not None:
                        val, expire_time = item
                        if now >= expire_time:
                            del store[key]
                            item = None

                if item is None:
                    # NotFound (0x03)
                    resp_payload = struct.pack(">BB", 1, 3)
                    resp_frame = struct.pack(">I", len(resp_payload)) + resp_payload
                    sock.sendall(resp_frame)
                else:
                    val = item[0]
                    # Value (0x02)
                    resp_payload = struct.pack(">BBH", 1, 2, len(val)) + val
                    resp_frame = struct.pack(">I", len(resp_payload)) + resp_payload
                    sock.sendall(resp_frame)

            elif op == 3:  # PUT
                if len(payload) < 4:
                    break
                (key_len,) = struct.unpack(">H", payload[2:4])
                offset = 4
                if len(payload) < offset + key_len + 2:
                    break
                key = payload[offset : offset + key_len]
                offset += key_len
                (val_len,) = struct.unpack(">H", payload[offset : offset + 2])
                offset += 2
                if len(payload) < offset + val_len + 9:
                    break
                val = payload[offset : offset + val_len]
                offset += val_len
                ttl_tag = payload[offset]
                offset += 1
                (ttl_sec,) = struct.unpack(">Q", payload[offset : offset + 8])
                log_event(f"PUT {key.decode(errors='replace')} ttl={ttl_sec}")

                if b"fail_capacity" in key:
                    # Capacity Error (0x04)
                    msg = b"capacity full"
                    resp_payload = struct.pack(">BBB H", 1, 4, 4, len(msg)) + msg
                    resp_frame = struct.pack(">I", len(resp_payload)) + resp_payload
                    sock.sendall(resp_frame)
                else:
                    with lock:
                        store[key] = (val, now + ttl_sec)
                    # Success (0x01)
                    resp_payload = struct.pack(">BB", 1, 1)
                    resp_frame = struct.pack(">I", len(resp_payload)) + resp_payload
                    sock.sendall(resp_frame)
            else:
                break
    except Exception:
        pass
    finally:
        sock.close()


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    s.listen(64)
    while True:
        try:
            conn, _ = s.accept()
            t = threading.Thread(target=handle_client, args=(conn,), daemon=True)
            t.start()
        except Exception:
            break


if __name__ == "__main__":
    main()
