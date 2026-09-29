
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
telethon_fast_last_frame.py

Mục tiêu:
- Nghe video mới từ 1 Telegram channel ID.
- Tải 1 video bằng nhiều TelegramClient/MTProto connection song song.
- Mỗi worker tải một byte-range riêng của file.
- Ghép trực tiếp vào đúng offset của file đích.
- ffmpeg seek từ cuối và lấy frame cuối.
- Xóa video ngay sau khi lấy frame.

Cài:
    python3 -m pip install -U telethon cryptg
    brew install ffmpeg

LƯU Ý:
- Điền API_ID / API_HASH / CHANNEL_ID ở CONFIG.
- Lần chạy đầu login bằng Telegram như bình thường.
- Sau đó session chính được lưu trong FAST_SESSION.session.
"""

import asyncio
import math
import os
import shutil
import time
from pathlib import Path
from typing import Optional

from telethon import TelegramClient, events, utils
from telethon.network.connection.tcpabridged import ConnectionTcpAbridged
from telethon.sessions import MemorySession


# =========================
# TELEGRAM CONFIG
# =========================

API_ID = 22675834

API_HASH = "0a8136aa110ea15c4face2c0a475ee4c"

# Channel ID dạng -100xxxxxxxxxx
# CHANNEL_ID = -1002673982744 # kenh real
CHANNEL_ID = -1002304293548 # kenh test

SESSION = "fast_video"

WORKDIR = Path("./tg_fast_frames")
WORKDIR.mkdir(parents=True, exist_ok=True)

# Số connection tải song song.
# Khuyên test: 4 -> 6 -> 8.
PARALLEL_CONNECTIONS = 24

# Telegram/Telethon hỗ trợ request_size tới 512 KiB ở downloader.
CHUNK_SIZE = 512 * 1024

# Lấy frame cách cuối video một đoạn rất nhỏ.
END_SEEK_SECONDS = 0.10

# Nếu nhiều video tới cùng lúc, mặc định xử lý lần lượt để tất cả
# worker connection tập trung băng thông vào 1 video.
MAX_SIMULTANEOUS_VIDEOS = 1

# Nếu True, giữ video để debug.
KEEP_VIDEO = False

# ============================================================


main_client = TelegramClient(
    SESSION,
    API_ID,
    API_HASH,
    connection=ConnectionTcpAbridged,
    auto_reconnect=True,
    sequential_updates=False,
)

video_sem = asyncio.Semaphore(MAX_SIMULTANEOUS_VIDEOS)

# Pool các client clone dùng cùng authorization key nhưng có
# connection MTProto riêng.
download_clients: list[TelegramClient] = []

# Tránh init pool nhiều lần.
pool_lock = asyncio.Lock()


def now_hms() -> str:
    return time.strftime("%H:%M:%S")


def human_mb(n: int) -> float:
    return n / 1024 / 1024


def is_video_message(msg) -> bool:
    if getattr(msg, "video", None):
        return True

    f = getattr(msg, "file", None)
    mime = getattr(f, "mime_type", None)
    return bool(mime and mime.startswith("video/"))


def check_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise RuntimeError(
            "Không tìm thấy ffmpeg. Trên macOS chạy: brew install ffmpeg"
        )


async def clone_authorized_client(index: int) -> TelegramClient:
    """
    Clone session authorization hiện tại sang MemorySession.

    Mỗi clone có connection MTProto riêng nhưng dùng cùng auth key.
    Không cần nhập OTP lại.
    """
    src = main_client.session

    mem = MemorySession()
    mem.set_dc(
        src.dc_id,
        src.server_address,
        src.port,
    )
    mem.auth_key = src.auth_key

    c = TelegramClient(
        mem,
        API_ID,
        API_HASH,
        connection=ConnectionTcpAbridged,
        receive_updates=False,
        auto_reconnect=True,
        sequential_updates=False,
    )

    await c.connect()

    if not await c.is_user_authorized():
        await c.disconnect()
        raise RuntimeError(
            f"Worker {index}: cloned auth key không authorized."
        )

    return c


async def ensure_download_pool() -> None:
    global download_clients

    if len(download_clients) == PARALLEL_CONNECTIONS:
        return

    async with pool_lock:
        if len(download_clients) == PARALLEL_CONNECTIONS:
            return

        # Dọn pool cũ nếu có.
        for c in download_clients:
            try:
                await c.disconnect()
            except Exception:
                pass
        download_clients = []

        t0 = time.perf_counter()

        # Connect song song.
        results = await asyncio.gather(
            *[
                clone_authorized_client(i)
                for i in range(PARALLEL_CONNECTIONS)
            ]
        )

        download_clients = list(results)

        print(
            f"[POOL] {len(download_clients)} MTProto connections ready "
            f"in {time.perf_counter() - t0:.3f}s"
        )


def split_ranges(file_size: int, workers: int) -> list[tuple[int, int]]:
    """
    Chia file thành các vùng liên tục, boundary theo CHUNK_SIZE.

    Return:
        [(start_byte, end_byte), ...]
        end_byte exclusive.
    """
    total_chunks = math.ceil(file_size / CHUNK_SIZE)
    workers = min(workers, total_chunks)

    base = total_chunks // workers
    extra = total_chunks % workers

    ranges = []
    chunk_index = 0

    for i in range(workers):
        count = base + (1 if i < extra else 0)

        start = chunk_index * CHUNK_SIZE
        end = min(file_size, (chunk_index + count) * CHUNK_SIZE)

        ranges.append((start, end))
        chunk_index += count

    return ranges


async def download_range(
    worker_id: int,
    client: TelegramClient,
    document,
    output_path: Path,
    start: int,
    end: int,
    file_size: int,
    dc_id: Optional[int],
) -> int:
    """
    Tải byte range [start, end) bằng 1 MTProto connection riêng.
    """
    wanted = end - start

    if wanted <= 0:
        return 0

    max_chunks = math.ceil(wanted / CHUNK_SIZE)

    stream = client.iter_download(
        document,
        offset=start,
        limit=max_chunks,
        chunk_size=CHUNK_SIZE,
        request_size=CHUNK_SIZE,
        file_size=file_size,
        dc_id=dc_id,
    )

    downloaded = 0

    try:
        # Mỗi worker dùng file descriptor riêng.
        with open(output_path, "r+b", buffering=0) as f:
            f.seek(start)

            async for block in stream:
                if isinstance(block, memoryview):
                    block = block.tobytes()

                remaining = wanted - downloaded
                if remaining <= 0:
                    break

                if len(block) > remaining:
                    block = block[:remaining]

                f.write(block)
                downloaded += len(block)

                if downloaded >= wanted:
                    break

    finally:
        try:
            await stream.close()
        except Exception:
            pass

    if downloaded != wanted:
        raise RuntimeError(
            f"worker={worker_id} thiếu data: "
            f"{downloaded}/{wanted} bytes"
        )

    return downloaded


async def parallel_download_document(
    document,
    output_path: Path,
) -> None:
    """
    Parallel full-file downloader.

    Khác client.download_media/download_file:
    file được chia range và mỗi range chạy trên 1 TelegramClient connection.
    """
    await ensure_download_pool()

    file_size = int(document.size)
    dc_id = getattr(document, "dc_id", None)

    if file_size <= 0:
        raise RuntimeError("Telegram document.size không hợp lệ")

    ranges = split_ranges(file_size, len(download_clients))

    # Preallocate logical file size.
    # truncate tạo file đúng size ngay; các worker ghi vào offset riêng.
    with open(output_path, "wb") as f:
        f.truncate(file_size)

    tasks = []

    for worker_id, ((start, end), worker) in enumerate(
        zip(ranges, download_clients)
    ):
        tasks.append(
            asyncio.create_task(
                download_range(
                    worker_id=worker_id,
                    client=worker,
                    document=document,
                    output_path=output_path,
                    start=start,
                    end=end,
                    file_size=file_size,
                    dc_id=dc_id,
                )
            )
        )

    result = await asyncio.gather(*tasks)

    total = sum(result)

    if total != file_size:
        raise RuntimeError(
            f"Downloaded byte mismatch: {total} != {file_size}"
        )


async def extract_last_frame(
    video_path: Path,
    output_path: Path,
) -> None:
    """
    Seek trực tiếp từ cuối file.

    -sseof đặt trước -i để input seeking.
    Không decode toàn bộ video từ đầu.
    """
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-sseof",
        f"-{END_SEEK_SECONDS}",
        "-i",
        str(video_path),
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-q:v",
        "2",
        "-y",
        str(output_path),
    ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )

    _, stderr = await proc.communicate()

    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg error ({proc.returncode}): "
            f"{stderr.decode(errors='ignore').strip()}"
        )


async def process_video(msg) -> None:
    async with video_sem:
        document = getattr(msg, "document", None)

        if document is None:
            print(f"[SKIP] msg={msg.id}: không có Document")
            return

        size = int(getattr(document, "size", 0) or 0)
        size_mb = human_mb(size)

        file_dc = getattr(document, "dc_id", None)
        session_dc = main_client.session.dc_id

        video_path = WORKDIR / f"{msg.id}.mp4"
        frame_path = WORKDIR / f"{msg.id}_last.jpg"

        print()
        print(
            f"[NEW] msg={msg.id} "
            f"size={size_mb:.2f} MB "
            f"time={now_hms()}"
        )

        print(
            f"[DC] session={session_dc} "
            f"file={file_dc} "
            f"workers={PARALLEL_CONNECTIONS}"
        )

        total_t0 = time.perf_counter()

        try:
            # ========================================================
            # DOWNLOAD
            # ========================================================
            dl_t0 = time.perf_counter()

            await parallel_download_document(
                document=document,
                output_path=video_path,
            )

            dl_s = time.perf_counter() - dl_t0

            speed = size_mb / dl_s if dl_s > 0 else 0

            print(
                f"[DOWNLOAD] {dl_s:.3f}s | "
                f"{speed:.2f} MB/s | "
                f"{PARALLEL_CONNECTIONS} connections"
            )

            # ========================================================
            # FRAME
            # ========================================================
            frame_t0 = time.perf_counter()

            await extract_last_frame(
                video_path,
                frame_path,
            )

            frame_s = time.perf_counter() - frame_t0

            print(
                f"[FRAME] {frame_s:.3f}s -> {frame_path}"
            )

            # ========================================================
            # OCR HOOK
            # ========================================================
            #
            # Nếu muốn gọi OCR localhost:8889 sau này,
            # đặt code OCR ở đây.
            #
            # Ví dụ flow:
            #
            # frame -> base64 -> POST /ocr -> lấy code
            #
            # ========================================================

            total_s = time.perf_counter() - total_t0

            print(f"[TOTAL] {total_s:.3f}s")

        except Exception as e:
            print(
                f"[ERROR] msg={msg.id}: "
                f"{type(e).__name__}: {e}"
            )

        finally:
            if not KEEP_VIDEO:
                try:
                    video_path.unlink(missing_ok=True)
                except Exception:
                    pass


@main_client.on(events.NewMessage(chats=CHANNEL_ID))
async def on_new_message(event):
    msg = event.message

    if not is_video_message(msg):
        return

    # Không giữ event callback chờ download.
    # Tạo task xử lý riêng ngay.
    asyncio.create_task(process_video(msg))


async def main():
    check_ffmpeg()

    await main_client.start()

    me = await main_client.get_me()

    print(
        f"[READY] logged in: "
        f"{getattr(me, 'username', None) or me.id}"
    )
    print(f"[WATCH] {CHANNEL_ID}")
    print(f"[SESSION_DC] {main_client.session.dc_id}")
    print(f"[OUT] {WORKDIR.resolve()}")

    # Warm pool trước khi video tới.
    # Quan trọng: tránh mất thời gian tạo 6 connection lúc video xuất hiện.
    await ensure_download_pool()

    print(
        f"[INFO] waiting for new videos... "
        f"parallel={PARALLEL_CONNECTIONS}"
    )

    try:
        await main_client.run_until_disconnected()

    finally:
        for c in download_clients:
            try:
                await c.disconnect()
            except Exception:
                pass

        try:
            await main_client.disconnect()
        except Exception:
            pass


if __name__ == "__main__":
    asyncio.run(main())
