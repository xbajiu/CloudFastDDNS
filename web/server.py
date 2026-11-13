#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CloudFastDDNS Web Control Server
Port: 9909
Volume Path: /opt/cloudfastddns/
"""

import csv
import datetime
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "9909"))
DATA_DIR = os.environ.get("DATA_DIR", "/opt/cloudfastddns")
APP_DIR = os.environ.get("APP_DIR", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

CONFIG_PATH = os.path.join(DATA_DIR, "config.conf")
DEFAULT_CONFIG_PATH = os.path.join(APP_DIR, "config.conf")
RESULT_CSV_PATH = os.path.join(DATA_DIR, "result.csv")
ALT_RESULT_CSV_PATH = os.path.join(DATA_DIR, "cf_ddns", "result.csv")
RUN_LOG_PATH = os.path.join(DATA_DIR, "run.log")
FLAG_FILE_PATH = os.path.join(DATA_DIR, ".ran_before")
CFST_BIN_PATH = os.path.join(DATA_DIR, "cf_ddns", "cfst")

ANSI_ESCAPE_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

# Match cfst progress bar frames:
# e.g. "4257 / 5955 [----------------------------------------------------↗____________________] 可用: 1584"
# or   "1 / 10 [--------↖______]"
CFST_LATENCY_BAR_RE = re.compile(
    r"(\d+)\s*/\s*(\d+)\s*\[[-_↖↗↘↙\s.=]*\]\s*可用:\s*(\d+)"
)
CFST_DOWNLOAD_BAR_RE = re.compile(
    r"(\d+)\s*/\s*(\d+)\s*\[[-_↖↗↘↙\s.=]*\]"
)
CFST_BAR_NOISE_RE = re.compile(
    r"(?:\d+\s*/\s*\d+\s*)?\[?[-_↖↗↘↙.=]{4,}\]?(?:\s*可用:\s*\d+)?"
)

# Default structured configuration values (strictly based on lee1080 main branch)
DEFAULT_CONFIG = {
    "PROXY": "https://gh-proxy.com/",
    "AUTO_RUN": "true",
    "TIMING": "0 */6 * * *",
    "IP_ADDR": "ipv4",
    "IP_PR_IP": "0",
    "IP_TO_HOSTS": "false",
    "DNS_PROVIDER": "1",
    "hostname": [],
    "x_email": "",
    "api_key": "",
    "MULTI_IP": "false",
    "MULTI_IP_NUM": "3",
    "dnspod_token": "",
    "LINE": "0",
    "CFST_URL": "https://cf.xiu2.xyz/url",
    "CFST_TP": "443",
    "CFST_DT": "10",
    "CFST_STM": "",
    "httping_code": "",
    "cfcolo": "",
    "CFST_N": "200",
    "CFST_T": "4",
    "CFST_DN": "10",
    "CFST_TL": "300",
    "CFST_TLL": "0",
    "CFST_TLR": "0.2",
    "CFST_SL": "5",
    "telegramBotToken": "",
    "telegramBotUserId": "",
    "Proxy_TG": "",
    "PushPlusToken": "",
    "ServerSendKey": "",
    "PushDeerPushKey": "",
    "CORPID": "",
    "SECRET": "",
    "AGENTID": "",
    "USERID": "",
    "Proxy_WX": "",
    "Synology_Chat_URL": "",
}


def sanitize_existing_line(line: str) -> str:
    """Clean up any historical log lines that contain cfst progress bar noise."""
    clean = ANSI_ESCAPE_RE.sub("", line).strip("\r\n")
    if not clean:
        return ""
    # If the line contains cfst progress bars, convert to a single clean summary
    lat_matches = CFST_LATENCY_BAR_RE.findall(clean)
    if lat_matches:
        cur, total, avail = lat_matches[-1]
        pct = int(int(cur) * 100 / int(total)) if int(total) > 0 else 100
        return f"[测速进度] 延迟测速: {cur} / {total} ({pct}%) | 可用: {avail}"
    dl_matches = CFST_DOWNLOAD_BAR_RE.findall(clean)
    if dl_matches:
        cur, total = dl_matches[-1]
        pct = int(int(cur) * 100 / int(total)) if int(total) > 0 else 100
        return f"[测速进度] 下载测速: {cur} / {total} ({pct}%)"
    if any(ch in clean for ch in ("↖", "↗", "↘", "↙")) or "----------" in clean or "__________" in clean:
        clean = CFST_BAR_NOISE_RE.sub("", clean).strip()
    return clean


class TaskRunner:
    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.status = "idle"  # idle | running | stopped | error
        self.phase = "空闲待命"
        self.start_time = None
        self.end_time = None
        self.last_exit_code = None
        self.log_lines = []
        self.transient_line = ""
        self.max_log_lines = 1500
        self._last_stdout_progress_ts = 0.0
        self._last_stdout_progress_text = ""
        self._cfst_stage = None  # None | "latency" | "download"
        self._load_existing_logs()

    def _load_existing_logs(self):
        if os.path.exists(RUN_LOG_PATH):
            try:
                with open(RUN_LOG_PATH, "r", encoding="utf-8", errors="replace") as f:
                    cleaned = []
                    for raw in f.readlines():
                        s = sanitize_existing_line(raw)
                        if s and (not cleaned or cleaned[-1] != s):
                            cleaned.append(s)
                    self.log_lines = cleaned[-self.max_log_lines :]
                # Rewrite cleaned log file so old messy progress bars are gone immediately
                with open(RUN_LOG_PATH, "w", encoding="utf-8") as f:
                    for s in self.log_lines:
                        f.write(s + "\n")
            except Exception:
                pass

    def _write_log_line(self, clean: str):
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
            with open(RUN_LOG_PATH, "a", encoding="utf-8") as f:
                f.write(clean + "\n")
        except Exception:
            pass

    def _commit_transient_progress(self):
        line_to_log = ""
        should_print = False
        with self.lock:
            if self.transient_line:
                line_to_log = self.transient_line
                self.transient_line = ""
                self._cfst_stage = None
                if not self.log_lines or self.log_lines[-1] != line_to_log:
                    self.log_lines.append(line_to_log)
                    if len(self.log_lines) > self.max_log_lines:
                        self.log_lines = self.log_lines[-self.max_log_lines :]
                    self._write_log_line(line_to_log)
                    should_print = (line_to_log != self._last_stdout_progress_text)
                    if should_print:
                        self._last_stdout_progress_text = line_to_log
                        self._last_stdout_progress_ts = time.time()
        if should_print and line_to_log:
            print(line_to_log, flush=True)

    def _append_log(self, line: str):
        clean = sanitize_existing_line(line)
        if not clean:
            return
        is_progress = clean.startswith("[测速进度]")
        if not is_progress:
            # Flush any partial progress bar (e.g. "1 / 5 (20%)") before transitioning to tables/logs
            self._commit_transient_progress()

        should_print = True
        with self.lock:
            if is_progress:
                self.transient_line = ""
                self._cfst_stage = None
            # Avoid duplicate consecutive progress/log lines
            if self.log_lines and self.log_lines[-1] == clean:
                return
            self.log_lines.append(clean)
            if len(self.log_lines) > self.max_log_lines:
                self.log_lines = self.log_lines[-self.max_log_lines :]
            self._detect_phase(clean)
            self._write_log_line(clean)
            if is_progress:
                should_print = (clean != self._last_stdout_progress_text)
                if should_print:
                    self._last_stdout_progress_text = clean
                    self._last_stdout_progress_ts = time.time()
        # Print to container stdout immediately so Portainer / docker logs -f sees real-time logs
        if should_print:
            print(clean, flush=True)

    def _update_progress(self, progress_text: str, phase_text: str, stage: str = None):
        now = time.time()
        with self.lock:
            prev_transient = self.transient_line
            self.transient_line = progress_text
            self.phase = phase_text
            if stage:
                self._cfst_stage = stage
            changed = (progress_text != self._last_stdout_progress_text)
            elapsed = now - self._last_stdout_progress_ts
            is_complete = "(100%)" in progress_text
            should_print_stdout = (
                (changed and (is_complete or elapsed >= 1.5))
                or (not changed and prev_transient != "" and elapsed >= 20.0)
            )
            if should_print_stdout:
                self._last_stdout_progress_ts = now
                self._last_stdout_progress_text = progress_text
        if should_print_stdout:
            print(progress_text, flush=True)

    def _detect_phase(self, line: str):
        if "首次部署初始化" in line or "正在下载:" in line:
            self.phase = "正在初始化环境与组件..."
        elif "反向代理列表" in line:
            self.phase = "正在更新反代 IP 列表..."
        elif "开始延迟测速" in line:
            self.phase = "正在执行延迟测速..."
            self._cfst_stage = "latency"
        elif "开始下载测速" in line:
            self.phase = "正在执行下载测速..."
            self._cfst_stage = "download"
        elif "正在更新域名" in line or "成功指向IP地址" in line or "更新成功" in line or "已成功" in line:
            self.phase = "正在同步更新 DNS 解析记录..."
            self._cfst_stage = None
        elif "推送" in line:
            self.phase = "正在发送消息推送通知..."
            self._cfst_stage = None
        elif "测速完毕" in line:
            self.phase = "测速完成，准备更新解析..."
            self._cfst_stage = None

    def clear_logs(self):
        with self.lock:
            self.log_lines = []
            self.transient_line = ""
            self._last_stdout_progress_text = ""
            self._cfst_stage = None
            try:
                if os.path.exists(RUN_LOG_PATH):
                    with open(RUN_LOG_PATH, "w", encoding="utf-8") as f:
                        f.write("")
            except Exception:
                pass

    def get_logs(self):
        with self.lock:
            lines = list(self.log_lines)
            if self.status == "running" and self.transient_line:
                lines.append(self.transient_line)
            return lines

    def is_running(self):
        with self.lock:
            return self.process is not None and self.process.poll() is None

    def start(self, trigger="手动触发"):
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                return False, "优选任务正在运行中，请勿重复启动"

            self.status = "running"
            self.phase = "正在启动优选任务..."
            self.start_time = time.time()
            self.end_time = None
            self.transient_line = ""
            self._last_stdout_progress_text = ""
            self._last_stdout_progress_ts = 0.0
            self._cfst_stage = None

        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self._append_log(f"[{now_str}] >>> 开始运行 ({trigger}) <<<")

        thread = threading.Thread(target=self._run_worker, daemon=True)
        thread.start()
        return True, "任务已开始运行"

    def _process_stream_buffer(self, text_buf: str, is_final: bool = False) -> str:
        """
        Process raw stdout text buffer from start.sh / cfst:
        1. Extract live cfst progress bar frames (which do not emit \\n until completion)
           and convert them into a single clean progress indicator.
        2. Flush complete lines (ending with \\n) to the permanent log and Portainer stdout.
        """
        text_buf = ANSI_ESCAPE_RE.sub("", text_buf).replace("\r", "\n")

        # First, process any complete lines (separated by \n)
        while "\n" in text_buf:
            line, text_buf = text_buf.split("\n", 1)
            line_clean = sanitize_existing_line(line)
            if line_clean:
                if line_clean.startswith("[测速进度]"):
                    new_stage = "latency" if "延迟测速" in line_clean else "download"
                    with self.lock:
                        stage_changed = bool(self._cfst_stage and self._cfst_stage != new_stage)
                    if stage_changed:
                        self._commit_transient_progress()
                    if "(100%)" not in line_clean:
                        self._update_progress(
                            line_clean, line_clean.replace("[测速进度] ", ""), stage=new_stage
                        )
                    else:
                        self._append_log(line_clean)
                else:
                    self._append_log(line_clean)

        # Next, inspect the remaining incomplete tail (where cfst writes progress bars without \n)
        lat_matches = list(CFST_LATENCY_BAR_RE.finditer(text_buf))
        if lat_matches:
            last = lat_matches[-1]
            cur, total, avail = last.group(1), last.group(2), last.group(3)
            pct = int(int(cur) * 100 / int(total)) if int(total) > 0 else 0
            msg = f"[测速进度] 延迟测速: {cur} / {total} ({pct}%) | 可用: {avail}"
            self._update_progress(msg, f"延迟测速中: {cur}/{total} (可用: {avail})", stage="latency")
            if cur == total:
                self._append_log(msg)
            text_buf = text_buf[last.end() :]
        else:
            with self.lock:
                in_latency = self._cfst_stage == "latency"
            # Check download speed progress bar (only when not waiting for "可用:" suffix in latency stage)
            dl_matches = list(CFST_DOWNLOAD_BAR_RE.finditer(text_buf))
            if dl_matches and not in_latency and "可用" not in text_buf:
                last = dl_matches[-1]
                after_bar = text_buf[last.end() :].strip()
                # Ensure it's not a partial latency bar that hasn't written "可用: xxx" yet
                if not after_bar.startswith("可"):
                    cur, total = last.group(1), last.group(2)
                    pct = int(int(cur) * 100 / int(total)) if int(total) > 0 else 0
                    msg = f"[测速进度] 下载测速: {cur} / {total} ({pct}%)"
                    self._update_progress(msg, f"下载测速中: {cur}/{total} ({pct}%)", stage="download")
                    if cur == total:
                        self._append_log(msg)
                    text_buf = text_buf[last.end() :]

        if is_final:
            if text_buf.strip():
                final_clean = sanitize_existing_line(text_buf)
                if final_clean:
                    self._append_log(final_clean)
                text_buf = ""
            self._commit_transient_progress()

        return text_buf

    def _run_worker(self):
        start_script = os.path.join(DATA_DIR, "start.sh")
        if not os.path.exists(start_script):
            start_script = os.path.join(APP_DIR, "start.sh")

        env = os.environ.copy()
        env["DATA_DIR"] = DATA_DIR
        env["PYTHONUNBUFFERED"] = "1"

        cmd = ["bash", start_script, "--cfg", CONFIG_PATH]
        kwargs = {
            "stdout": subprocess.PIPE,
            "stderr": subprocess.STDOUT,
            "cwd": DATA_DIR if os.path.exists(DATA_DIR) else APP_DIR,
            "env": env,
            "bufsize": 0,
        }
        if os.name != "nt":
            kwargs["start_new_session"] = True

        try:
            proc = subprocess.Popen(cmd, **kwargs)
            with self.lock:
                self.process = proc

            fd = proc.stdout.fileno()
            text_buf = ""
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                text_buf += chunk.decode("utf-8", errors="replace")
                text_buf = self._process_stream_buffer(text_buf, is_final=False)

            self._process_stream_buffer(text_buf, is_final=True)

            rc = proc.wait()
            now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with self.lock:
                self.end_time = time.time()
                self.last_exit_code = rc
                self.transient_line = ""
                self._cfst_stage = None
                if self.status == "stopped":
                    self.phase = "已手动终止运行"
                elif rc == 0:
                    self.status = "idle"
                    self.phase = "上次运行已完成"
                else:
                    self.status = "error"
                    self.phase = f"运行异常退出 (代码: {rc})"
                self.process = None

            if rc == 0:
                self._append_log(f"[{now_str}] >>> 任务执行完成 <<<")

        except Exception as e:
            self._append_log(f"[错误] 启动执行进程异常: {e}")
            with self.lock:
                self.end_time = time.time()
                self.status = "error"
                self.phase = f"执行异常: {e}"
                self.transient_line = ""
                self._cfst_stage = None
                self.process = None

    def stop(self):
        with self.lock:
            proc = self.process
            if proc is None or proc.poll() is not None:
                self.status = "idle"
                self.phase = "空闲待命"
                return False, "当前没有正在运行的任务"
            self.status = "stopped"
            self.phase = "正在终止运行..."

        try:
            if os.name != "nt":
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    proc.terminate()
                time.sleep(0.5)
                if proc.poll() is None:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except Exception:
                        proc.kill()
                subprocess.run(["pkill", "-f", CFST_BIN_PATH], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                proc.terminate()
        except Exception as e:
            self._append_log(f"[警告] 终止进程时发生异常: {e}")

        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self._append_log(f"[{now_str}] [停止] 用户已手动终止运行任务")
        with self.lock:
            self.end_time = time.time()
            self.phase = "已手动终止运行"
            self.transient_line = ""
            self._cfst_stage = None
        return True, "已停止运行任务"

    def get_status(self):
        with self.lock:
            running = self.process is not None and self.process.poll() is None
            status = "running" if running else self.status
            phase = self.phase
            last_exit_code = self.last_exit_code
            pid = self.process.pid if running else None
            duration = 0
            if self.start_time:
                end_t = time.time() if running else (self.end_time or self.start_time)
                duration = max(0, int(end_t - self.start_time))

            start_str = (
                datetime.datetime.fromtimestamp(self.start_time).strftime("%Y-%m-%d %H:%M:%S")
                if self.start_time
                else None
            )
            end_str = (
                datetime.datetime.fromtimestamp(self.end_time).strftime("%Y-%m-%d %H:%M:%S")
                if self.end_time
                else None
            )

        cfg = read_config()
        return {
            "status": status,
            "running": running,
            "phase": phase,
            "pid": pid,
            "start_time": start_str,
            "end_time": end_str,
            "duration": duration,
            "last_exit_code": last_exit_code,
            "initialized": os.path.exists(FLAG_FILE_PATH),
            "cfst_ready": os.path.exists(CFST_BIN_PATH),
            "proxy": cfg.get("PROXY", "https://gh-proxy.com/"),
            "config_path": CONFIG_PATH,
            "auto_run": cfg.get("AUTO_RUN", "true") == "true",
            "timing": cfg.get("TIMING", "0 */6 * * *"),
        }


runner = TaskRunner()


def ensure_data_dir():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(os.path.join(DATA_DIR, "cf_ddns"), exist_ok=True)
    if not os.path.exists(CONFIG_PATH) and os.path.exists(DEFAULT_CONFIG_PATH):
        shutil.copyfile(DEFAULT_CONFIG_PATH, CONFIG_PATH)


_REQUIRED_NONEMPTY_KEYS = {
    "AUTO_RUN",
    "TIMING",
    "IP_ADDR",
    "IP_PR_IP",
    "IP_TO_HOSTS",
    "DNS_PROVIDER",
    "MULTI_IP",
    "MULTI_IP_NUM",
    "LINE",
    "CFST_TP",
    "CFST_DT",
    "CFST_N",
    "CFST_T",
    "CFST_DN",
    "CFST_TL",
    "CFST_TLL",
    "CFST_TLR",
    "CFST_SL",
}


def _unescape_double_quoted(val: str) -> str:
    out = []
    i = 0
    n = len(val)
    while i < n:
        if val[i] == "\\" and i + 1 < n and val[i + 1] in ('"', "\\", "$", "`"):
            out.append(val[i + 1])
            i += 2
        else:
            out.append(val[i])
            i += 1
    return "".join(out)


def read_config() -> dict:
    ensure_data_dir()
    config = dict(DEFAULT_CONFIG)
    config["hostname"] = list(DEFAULT_CONFIG["hostname"])

    if not os.path.exists(CONFIG_PATH):
        return config

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()

        # Parse hostname=(...) array
        m_host = re.search(r"^\s*hostname\s*=\s*\(([^)]*)\)", content, re.MULTILINE)
        if m_host:
            raw_hosts = m_host.group(1).strip()
            config["hostname"] = [h.strip("\"'") for h in raw_hosts.split() if h.strip("\"'")]

        # Parse KEY=VALUE lines
        for line in content.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("hostname="):
                continue
            if "=" in stripped:
                k, v = stripped.split("=", 1)
                k = k.strip()
                v = v.strip()
                if v.startswith('"') and v.endswith('"') and len(v) >= 2:
                    v = _unescape_double_quoted(v[1:-1])
                elif v.startswith("'") and v.endswith("'") and len(v) >= 2:
                    v = v[1:-1]
                else:
                    v = v.split("#", 1)[0].strip()
                if k in config and k != "hostname":
                    if k in _REQUIRED_NONEMPTY_KEYS and v == "":
                        config[k] = DEFAULT_CONFIG[k]
                    else:
                        config[k] = v
    except Exception as e:
        print(f"[Error] Failed to read config.conf: {e}", flush=True)

    return config


def write_config(new_cfg: dict):
    ensure_data_dir()
    cfg = read_config()
    for k, v in new_cfg.items():
        if k in cfg:
            cfg[k] = v

    # Normalize hostname list and strip unsafe shell characters
    hosts = cfg.get("hostname", [])
    if isinstance(hosts, str):
        hosts = [h.strip() for h in re.split(r"[\s,]+", hosts) if h.strip()]
    elif isinstance(hosts, list):
        hosts = [str(h).strip() for h in hosts if str(h).strip()]
    else:
        hosts = []
    clean_hosts = []
    for h in hosts:
        cleaned = re.sub(r'[\r\n\s"\'()$`;&|<>\\]+', "", h)
        if cleaned:
            clean_hosts.append(cleaned)
    cfg["hostname"] = clean_hosts
    hosts_str = " ".join(clean_hosts)

    def q(val):
        s = str(val if val is not None else "").replace("\r", "").replace("\n", "").strip()
        s = s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
        return f'"{s}"'

    def raw_or_val(val, default=""):
        s = re.sub(r'[\r\n\s"\'`$;|&<>()\\]+', "", str(val if val is not None else "").strip())
        return s if s != "" else default

    for key in _REQUIRED_NONEMPTY_KEYS:
        if key != "TIMING":
            cfg[key] = raw_or_val(cfg.get(key), DEFAULT_CONFIG[key])

    timing_raw = str(cfg.get("TIMING") if cfg.get("TIMING") is not None else DEFAULT_CONFIG["TIMING"])
    timing_val = " ".join(timing_raw.replace("\r", " ").replace("\n", " ").split())
    if not timing_val:
        timing_val = DEFAULT_CONFIG["TIMING"]
    if len(timing_val.split()) != 5:
        raise ValueError("定时 Cron 表达式格式无效，应为 5 段空格分隔格式（例如: 0 */6 * * *）")
    cfg["TIMING"] = timing_val

    lines = [
        "# ==============================================================================",
        "# CloudFastDDNS 配置文件 (基于 lee1080/CloudflareSpeedTestDDNS main 分支)",
        "# 映射路径: /opt/cloudfastddns/config.conf",
        "# ==============================================================================",
        "",
        "# ------------------------------------------基础与工作模式配置------------------------------------------",
        "# --GitHub 代理地址--",
        f"PROXY={q(cfg.get('PROXY', 'https://gh-proxy.com/'))}",
        "",
        "# --是否开启定时运行--",
        f"AUTO_RUN={raw_or_val(cfg.get('AUTO_RUN'), 'true')}",
        "",
        "# --定时运行 Cron 表达式--",
        f"TIMING={q(cfg.get('TIMING', '0 */6 * * *'))}",
        "",
        "# --运行模式-- (ipv4 or ipv6)",
        f"IP_ADDR={raw_or_val(cfg.get('IP_ADDR'), 'ipv4')}",
        "",
        "# --是否使用反代ip-- (0=关闭，1=线路1，2=线路2)",
        f"IP_PR_IP={raw_or_val(cfg.get('IP_PR_IP'), '0')}",
        "",
        "# --是否同步更新到hosts-- (true or false)",
        f"IP_TO_HOSTS={raw_or_val(cfg.get('IP_TO_HOSTS'), 'false')}",
        "",
        "# --选择DNS服务商-- (1=cloudflare  2=dnspod)",
        f"DNS_PROVIDER={raw_or_val(cfg.get('DNS_PROVIDER'), '1')}",
        "",
        "# --填写需要DDNS的完整域名--",
        f"hostname=({hosts_str})",
        "",
        "# ------------------------------------------cloudflare配置------------------------------------------",
        "# --cloudflare账号邮箱--",
        f"x_email={q(cfg.get('x_email', ''))}",
        "",
        "# --Global API Key--",
        f"api_key={q(cfg.get('api_key', ''))}",
        "",
        "# --一个域名解析多个IP-- (false=一个域名一个IP，true=一个域名多个IP)",
        f"MULTI_IP={raw_or_val(cfg.get('MULTI_IP'), 'false')}",
        "",
        "# --每个域名解析的IP数量-- (仅 MULTI_IP=true 时生效)",
        f"MULTI_IP_NUM={raw_or_val(cfg.get('MULTI_IP_NUM'), '3')}",
        "",
        "# ------------------------------------------dnspod配置------------------------------------------",
        "# --dnspod的id,token--",
        f"dnspod_token={q(cfg.get('dnspod_token', ''))}",
        "",
        "# --选择线路-- (0=默认，1=电信，2=联通，3=移动，4=铁通，5=广电，6=教育网，7=境内，8=境外)",
        f"LINE={raw_or_val(cfg.get('LINE'), '0')}",
        "",
        "# ----------------------------------------CloudflareST配置----------------------------------------",
        "# --测速地址--",
        f"CFST_URL={q(cfg.get('CFST_URL', 'https://cf.xiu2.xyz/url'))}",
        "",
        "# --测速地址端口--",
        f"CFST_TP={raw_or_val(cfg.get('CFST_TP'), '443')}",
        "",
        "# --下载测速时间--",
        f"CFST_DT={raw_or_val(cfg.get('CFST_DT'), '10')}",
        "",
        "# --测速模式--",
        f"CFST_STM={q(cfg.get('CFST_STM', ''))}",
        "",
        "# --有效状态代码--",
        f"httping_code={q(cfg.get('httping_code', ''))}",
        "",
        "# --匹配指定地区--",
        f"cfcolo={q(cfg.get('cfcolo', ''))}",
        "",
        "# --测速线程数量--",
        f"CFST_N={raw_or_val(cfg.get('CFST_N'), '200')}",
        "",
        "# --延迟测速次数--",
        f"CFST_T={raw_or_val(cfg.get('CFST_T'), '4')}",
        "",
        "# --下载测速数量--",
        f"CFST_DN={raw_or_val(cfg.get('CFST_DN'), '10')}",
        "",
        "# --平均延迟上限--",
        f"CFST_TL={raw_or_val(cfg.get('CFST_TL'), '300')}",
        "",
        "# --平均延迟下限--",
        f"CFST_TLL={raw_or_val(cfg.get('CFST_TLL'), '0')}",
        "",
        "# --丢包几率上限--",
        f"CFST_TLR={raw_or_val(cfg.get('CFST_TLR'), '0.2')}",
        "",
        "# --下载速度下限--",
        f"CFST_SL={raw_or_val(cfg.get('CFST_SL'), '5')}",
        "",
        "# --------------------------------------------推送设置--------------------------------------------",
        "# ----TG推送设置----",
        f"telegramBotToken={q(cfg.get('telegramBotToken', ''))}",
        f"telegramBotUserId={q(cfg.get('telegramBotUserId', ''))}",
        f"Proxy_TG={q(cfg.get('Proxy_TG', ''))}",
        "",
        "# ----PushPlus设置----",
        f"PushPlusToken={q(cfg.get('PushPlusToken', ''))}",
        "",
        "# ----Server 酱推送设置----",
        f"ServerSendKey={q(cfg.get('ServerSendKey', ''))}",
        "",
        "# ----PushDeer推送设置----",
        f"PushDeerPushKey={q(cfg.get('PushDeerPushKey', ''))}",
        "",
        "# ----企业微信推送设置----",
        f"CORPID={q(cfg.get('CORPID', ''))}",
        f"SECRET={q(cfg.get('SECRET', ''))}",
        f"AGENTID={q(cfg.get('AGENTID', ''))}",
        f"USERID={q(cfg.get('USERID', ''))}",
        f"Proxy_WX={q(cfg.get('Proxy_WX', ''))}",
        "",
        "# ----Synology Chat推送----",
        f"Synology_Chat_URL={q(cfg.get('Synology_Chat_URL', ''))}",
        "",
    ]

    with open(CONFIG_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    sync_crontab(cfg)
    return cfg


def sync_crontab(cfg: dict):
    """Synchronize system crontab if running in Linux container."""
    if os.name == "nt":
        return
    cron_file = "/var/spool/cron/crontabs/root"
    cron_dir = os.path.dirname(cron_file)
    if not os.path.exists(cron_dir):
        return
    try:
        auto_run = str(cfg.get("AUTO_RUN", "true")).lower() == "true"
        timing = " ".join(str(cfg.get("TIMING", "0 */6 * * *")).replace("\r", " ").replace("\n", " ").split())
        lines = []
        if auto_run and timing:
            if len(timing.split()) == 5:
                lines.append(
                    f"{timing} curl -s -X POST http://127.0.0.1:{PORT}/api/start?trigger=cron >/dev/null 2>&1"
                )
            else:
                print(f"[Warn] Invalid TIMING cron expression skipped: {timing}", flush=True)
        with open(cron_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(("\n".join(lines) + "\n") if lines else "")
        # Trigger Alpine dcron reload
        with open(os.path.join(cron_dir, "cron.update"), "w", encoding="utf-8", newline="\n") as uf:
            uf.write("root\n")
    except Exception as e:
        print(f"[Warn] Failed to update crontab: {e}", flush=True)


def read_results():
    target = RESULT_CSV_PATH if os.path.exists(RESULT_CSV_PATH) else ALT_RESULT_CSV_PATH
    if not os.path.exists(target):
        return {"updated_at": None, "items": []}

    items = []
    updated_at = None
    try:
        mtime = os.path.getmtime(target)
        updated_at = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            reader = csv.reader(f)
            rows = list(reader)
            if len(rows) > 1:
                for idx, row in enumerate(rows[1:], start=1):
                    if not row or not row[0].strip():
                        continue
                    items.append(
                        {
                            "rank": idx,
                            "ip": row[0].strip() if len(row) > 0 else "",
                            "sent": row[1].strip() if len(row) > 1 else "",
                            "recv": row[2].strip() if len(row) > 2 else "",
                            "loss": row[3].strip() if len(row) > 3 else "",
                            "latency": row[4].strip() if len(row) > 4 else "",
                            "speed": row[5].strip() if len(row) > 5 else "",
                            "colo": row[6].strip() if len(row) > 6 else "",
                        }
                    )
    except Exception as e:
        print(f"[Error] Failed to parse result.csv: {e}", flush=True)

    return {"updated_at": updated_at, "items": items}


class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_json(self, data: dict, status=200):
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _send_file(self, filepath: str, content_type: str):
        if not os.path.exists(filepath):
            self.send_error(404, "File Not Found")
            return
        with open(filepath, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            self._send_file(os.path.join(STATIC_DIR, "index.html"), "text/html; charset=utf-8")
        elif path == "/api/status":
            self._send_json({"ok": True, "data": runner.get_status()})
        elif path == "/api/config":
            self._send_json({"ok": True, "data": read_config()})
        elif path == "/api/logs":
            self._send_json(
                {
                    "ok": True,
                    "data": {
                        "lines": runner.get_logs(),
                        "status": runner.get_status(),
                    },
                }
            )
        elif path == "/api/results":
            self._send_json({"ok": True, "data": read_results()})
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        try:
            length = max(0, int(self.headers.get("Content-Length", "0")))
        except (TypeError, ValueError):
            length = 0
        body_raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            body = json.loads(body_raw.decode("utf-8")) if body_raw else {}
            if not isinstance(body, dict):
                body = {}
        except Exception:
            self._send_json({"ok": False, "message": "无效的 JSON 请求体"}, status=400)
            return

        if path == "/api/config":
            try:
                saved = write_config(body)
                print("[CloudFastDDNS] 配置已更新并保存至 /opt/cloudfastddns/config.conf", flush=True)
                self._send_json({"ok": True, "message": "配置已保存至 /opt/cloudfastddns/config.conf", "data": saved})
            except Exception as e:
                self._send_json({"ok": False, "message": f"保存配置失败: {e}"}, status=500)
        elif path == "/api/start":
            trigger = "定时任务触发" if qs.get("trigger", [""])[0] == "cron" else "Web端手动启动"
            ok, msg = runner.start(trigger=trigger)
            self._send_json({"ok": ok, "message": msg, "data": runner.get_status()})
        elif path == "/api/stop":
            ok, msg = runner.stop()
            self._send_json({"ok": ok, "message": msg, "data": runner.get_status()})
        elif path == "/api/logs/clear":
            runner.clear_logs()
            self._send_json({"ok": True, "message": "日志已清空"})
        else:
            self.send_error(404, "Not Found")


def main():
    ensure_data_dir()
    cfg = read_config()
    sync_crontab(cfg)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), RequestHandler)
    print(f"[CloudFastDDNS] Web 管理服务已启动: http://0.0.0.0:{PORT}", flush=True)
    print(f"[CloudFastDDNS] 配置文件映射目录: {DATA_DIR}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
