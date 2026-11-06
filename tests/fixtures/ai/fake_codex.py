"""Deterministic JSONL app-server used by the AI integration tests."""
import json
import sys
import threading
import time

scenario = sys.argv[1]
lock = threading.Lock()
turns = 0


def send(message):
    encoded = json.dumps(message) + "\n"
    with lock:
        # Exercise the client's buffering across partial JSONL reads.
        midpoint = len(encoded) // 2
        sys.stdout.write(encoded[:midpoint])
        sys.stdout.flush()
        sys.stdout.write(encoded[midpoint:])
        sys.stdout.flush()


def respond(request, result):
    send({"id": request["id"], "result": result})


def complete(thread_id, turn_id, payload):
    output = {}
    if payload.get("review_kind") == "guide":
        steps = []
        generated_files = []
        for file in payload["files"]:
            if scenario == "generated_guide" and file["file"] == "package-lock.json":
                generated_files.append(file["id"])
                continue
            excerpts = []
            if file["changes"]:
                change = file["changes"][0]
                side = "modified" if change["modified"]["lines"] else "original"
                start = change[side]["start_line"]
                excerpts = [{"file_id": file["id"], "change_id": change["id"],
                             "side": side, "start_line": start, "end_line": start,
                             "caption": "Actual changed code"}]
            steps.append({"title": "Review " + file["file"],
                          "summary": "Explain the change in " + file["file"],
                          "attention": "Check the intended behavior.",
                          "excerpts": excerpts, "files": [] if excerpts else [file["id"]],
                          "notes": ([{"excerpt": 1, "line": excerpts[0]["start_line"],
                                      "text": "This connects to the next component."}] if excerpts else [])})
        output = {"steps": steps, "generated_files": generated_files}
        if scenario == "grouped_guide":
            output = {"generated_files": [], "steps": [{"title": "Related changes", "summary": "Review the changes together.",
                                 "attention": "", "excerpts": [],
                                 "files": [file["id"] for file in payload["files"]],
                                 "notes": []}]}
        if scenario == "bad_guide":
            output["steps"][0]["excerpts"][0]["file_id"] = 999
    text = "invalid JSON" if scenario == "invalid" else json.dumps(output)
    send({"method": "item/completed", "params": {"threadId": thread_id, "item": {"type": "agentMessage", "text": text}}})
    turn = {"id": turn_id, "status": "completed", "items": []}
    if scenario in ("failed", "slow_failed"):
        turn.update(status="failed", error={"message": "Usage limit reached"})
    send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": turn}})


def stream(thread_id, turn_id, payload):
    for index in range(8):
        time.sleep(0.1)
        send({"method": ("item/reasoning/textDelta" if index < 4 else "item/agentMessage/delta"),
              "params": {"threadId": "unrelated-thread" if scenario == "unrelated_stream" else thread_id,
                         "turnId": turn_id, "itemId": "item-1", "delta": "partial text"}})
    if scenario == "streaming":
        complete(thread_id, turn_id, payload)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request:
        continue
    if method == "initialize":
        respond(request, {"userAgent": "fake-codex"})
    elif method == "account/read":
        respond(request, {"account": None if scenario == "logged_out" else {"type": "chatgpt", "planType": "plus"}})
    elif method == "account/login/start":
        respond(request, {"type": "chatgpt", "loginId": "login-1", "authUrl": "https://example.invalid/sign-in"})
        send({"method": "account/login/completed", "params": {"loginId": "login-1", "success": True, "error": None}})
    elif method == "config/read":
        respond(request, {"config": {"mcp_servers": {"test_server": {"enabled": True}}}})
    elif method == "thread/start":
        params = request["params"]
        assert params["ephemeral"] is True
        assert params["sandbox"] == "read-only"
        assert params["config"]["mcp_servers"]["test_server"]["enabled"] is False
        assert params["config"]["features"]["shell_tool"] is False
        assert params["config"]["features"]["multi_agent"] is False
        assert params["config"]["features"]["plugins"] is False
        respond(request, {"thread": {"id": "thread-" + str(request["id"])}})
    elif method == "turn/start":
        if scenario == "crash":
            sys.exit(7)
        turns += 1
        params = request["params"]
        payload = json.loads(params["input"][0]["text"].split("\n\n", 1)[1])
        if payload.get("review_kind") == "guide":
            assert "steps" in params["outputSchema"]["properties"]
            assert "generated_files" in params["outputSchema"]["required"]
            assert "Exclude generated files" in params["input"][0]["text"]
        turn_id = "turn-" + str(turns)
        respond(request, {"turn": {"id": turn_id, "status": "inProgress"}})
        if scenario in ("streaming", "streamed_hang", "unrelated_stream"):
            worker = threading.Thread(target=stream, args=(params["threadId"], turn_id, payload), daemon=True)
            worker.start()
        elif scenario != "hang":
            delay = 0.35 if scenario in ("slow", "slow_failed") else 0.01
            timer = threading.Timer(delay, complete, (params["threadId"], turn_id, payload))
            timer.daemon = True
            timer.start()
    elif method == "test/stats":
        respond(request, {"turns": turns})
    else:
        respond(request, {})
