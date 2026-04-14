"""
识货(Shihuo) 앱 가격 수집 자동화
스크린샷 + Claude API 비전 방식 — 좌표 캘리브레이션 불필요

원리:
  1. 识货 앱 창만 캡처 (전체 화면 X)
  2. Claude API (vision)에 이미지 전송
  3. AI가 UI 요소 위치/텍스트 판단 → 이미지 내 좌표 반환 or 데이터 추출
  4. 이미지 좌표 → 절대 화면 좌표로 환산 → pyautogui.click()
  5. 반복

사전 설정:
  1. pip install anthropic pyautogui pillow
  2. export ANTHROPIC_API_KEY="sk-ant-..."
  3. 시스템 설정 > 개인정보 보호 > 화면 녹화 에서 Terminal 허용
  4. 识货 앱 열어놓기

사용법:
  python3 china_price.py --model ID6016             # 빠른 검색 (기본 정보만)
  python3 china_price.py --model ID6016 --full       # 전체 수집 (사이즈+판매처+스펙)
  python3 china_price.py --check                     # 사전 요건 체크
"""

import argparse
import base64
import io
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

BASE_DIR = Path(__file__).parent
RESULTS_DIR = BASE_DIR / "china_prices"
SCREENSHOTS_DIR = BASE_DIR / "debug_screenshots"

VISION_MODEL = "claude-sonnet-4-20250514"
MAX_VISION_TOKENS = 4096

# 화면 전환 후 기본 대기 시간(초)
WAIT_SHORT = 1.0
WAIT_MEDIUM = 2.0
WAIT_LONG = 3.0


# ═══════════════════════════════════════════
# Retina 스케일 감지
# ═══════════════════════════════════════════

def get_retina_scale():
    """macOS Retina 디스플레이 스케일 팩터를 반환한다.
    Retina 디스플레이는 논리 좌표 1pt = 물리 2px이다.
    pyautogui.screenshot()은 물리 픽셀 크기의 이미지를 반환하지만,
    pyautogui.click()은 논리 좌표를 사용한다.
    """
    try:
        from Quartz import CGMainDisplayID, CGDisplayPixelsWide
        from AppKit import NSScreen
        main_screen = NSScreen.mainScreen()
        scale = main_screen.backingScaleFactor()
        return scale
    except Exception:
        # Quartz 못 쓰면 pyautogui로 추정
        try:
            import pyautogui
            ss = pyautogui.screenshot()
            screen_w, _ = pyautogui.size()
            return ss.width / screen_w
        except Exception:
            return 2.0  # macOS 기본 Retina


# ═══════════════════════════════════════════
# 사전 요건 체크
# ═══════════════════════════════════════════

def check_prerequisites():
    """모든 사전 요건 확인"""
    ok = True
    print("=== 사전 요건 체크 ===\n")

    # 1) pyautogui
    try:
        import pyautogui
        pyautogui.FAILSAFE = True
        print("  [OK] pyautogui")
    except ImportError:
        print("  [FAIL] pyautogui → pip3 install pyautogui pillow")
        ok = False

    # 2) anthropic
    try:
        import anthropic
        print("  [OK] anthropic SDK")
    except ImportError:
        print("  [FAIL] anthropic → pip3 install anthropic")
        ok = False

    # 3) API 키
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        print(f"  [OK] ANTHROPIC_API_KEY ({len(key)} chars)")
    else:
        print("  [FAIL] ANTHROPIC_API_KEY 미설정")
        print("         export ANTHROPIC_API_KEY=\"sk-ant-...\"")
        ok = False

    # 4) 스크린샷 권한
    if _test_screenshot():
        print("  [OK] 화면 녹화 권한")
    else:
        print("  [FAIL] 화면 녹화 권한 없음")
        print("         시스템 설정 > 개인정보 보호 > 화면 녹화 > Terminal 허용")
        ok = False

    # 5) Retina 스케일
    scale = get_retina_scale()
    print(f"  [OK] Retina 스케일: {scale}x")

    # 6) 识货 앱
    win = get_window_info()
    if win:
        print(f"  [OK] 识货 앱 실행 중 (위치: {win['x']},{win['y']} 크기: {win['width']}x{win['height']})")
    else:
        print("  [WARN] 识货 앱 미실행 → 앱을 먼저 열어주세요")

    print(f"\n{'=== 준비 완료! ===' if ok else '=== 위 항목을 해결하세요 ==='}")
    return ok


def _test_screenshot():
    try:
        import pyautogui
        s = pyautogui.screenshot()
        return s is not None and s.size[0] > 0
    except Exception:
        return False


# ═══════════════════════════════════════════
# 识货 앱 창 관리
# ═══════════════════════════════════════════

def get_window_info():
    """AppleScript로 识货 앱 창의 위치/크기를 가져온다 (논리 좌표)."""
    script = '''
    tell application "System Events"
        tell process "ShihuoIPhone"
            set frontWindow to first window
            set windowPos to position of frontWindow
            set windowSize to size of frontWindow
            return (item 1 of windowPos as text) & "," & (item 2 of windowPos as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
        end tell
    end tell
    '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = result.stdout.strip().split(',')
            return {
                "x": int(parts[0].strip()),
                "y": int(parts[1].strip()),
                "width": int(parts[2].strip()),
                "height": int(parts[3].strip()),
            }
    except Exception as e:
        print(f"  [WARN] 창 위치 감지 실패: {e}")
    return None


def activate_app():
    """识货 앱을 앞으로 가져온다."""
    subprocess.run(
        ['osascript', '-e', 'tell application "识货" to activate'],
        capture_output=True
    )
    time.sleep(WAIT_SHORT)


# ═══════════════════════════════════════════
# 스크린샷 캡처 + 좌표 환산
# ═══════════════════════════════════════════

def capture_app_window(save_debug=False, label=""):
    """识货 앱 창 영역만 캡처한다.

    Returns:
        (PIL.Image, window_info_dict) — window_info는 논리 좌표
        창을 못 찾으면 (None, None) 반환
    """
    import pyautogui

    win = get_window_info()
    if not win:
        print("  [ERROR] 识货 앱 창을 찾을 수 없습니다.")
        return None, None

    # pyautogui.screenshot(region=...)은 논리 좌표를 받지만
    # 반환하는 이미지는 물리 픽셀 크기 (Retina에서 2배)
    img = pyautogui.screenshot(
        region=(win["x"], win["y"], win["width"], win["height"])
    )

    if save_debug:
        SCREENSHOTS_DIR.mkdir(exist_ok=True)
        ts = datetime.now().strftime("%H%M%S")
        fname = f"{label}_{ts}.png" if label else f"debug_{ts}.png"
        img.save(SCREENSHOTS_DIR / fname)

    return img, win


def image_to_base64(img):
    """PIL Image → base64 문자열"""
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    return base64.b64encode(buf.getvalue()).decode()


def image_coords_to_screen(ix, iy, window_info):
    """AI가 반환한 이미지 내 좌표(px)를 절대 화면 좌표(논리 pt)로 환산한다.

    AI는 캡처된 이미지(물리 픽셀)를 보고 좌표를 반환한다.
    macOS Retina에서는 이미지 크기가 논리 크기의 2배이므로,
    이미지 좌표를 스케일로 나눈 뒤 앱 창 위치를 더해야 한다.

    abs_x = window_x + (image_x / retina_scale)
    abs_y = window_y + (image_y / retina_scale)
    """
    scale = get_retina_scale()
    abs_x = window_info["x"] + (ix / scale)
    abs_y = window_info["y"] + (iy / scale)
    return int(abs_x), int(abs_y)


# ═══════════════════════════════════════════
# Claude API 비전
# ═══════════════════════════════════════════

_anthropic_client = None

def _get_client():
    global _anthropic_client
    if _anthropic_client is None:
        import anthropic
        _anthropic_client = anthropic.Anthropic()
    return _anthropic_client


def ask_vision(image, prompt, parse_json=False, retries=2):
    """Claude API에 스크린샷 + 프롬프트를 전송한다.

    Args:
        image: PIL Image
        prompt: 질문 텍스트
        parse_json: True면 응답에서 JSON을 파싱하여 반환
        retries: JSON 파싱 실패 시 재시도 횟수
    """
    img_b64 = image_to_base64(image)
    client = _get_client()

    for attempt in range(retries + 1):
        response = client.messages.create(
            model=VISION_MODEL,
            max_tokens=MAX_VISION_TOKENS,
            messages=[{
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": img_b64,
                        }
                    },
                    {"type": "text", "text": prompt}
                ]
            }]
        )

        text = response.content[0].text

        if not parse_json:
            return text

        # JSON 파싱 시도: 객체 또는 배열
        parsed = _extract_json(text)
        if parsed is not None:
            return parsed

        if attempt < retries:
            print(f"  [WARN] JSON 파싱 실패 (시도 {attempt+1}/{retries+1}), 재시도...")
        else:
            print(f"  [WARN] JSON 파싱 최종 실패. 원본: {text[:300]}")
            return None


def _extract_json(text):
    """텍스트에서 JSON 객체 또는 배열을 추출한다."""
    # ```json ... ``` 블록 먼저
    m = re.search(r'```(?:json)?\s*([\s\S]*?)```', text)
    if m:
        try:
            return json.loads(m.group(1).strip())
        except json.JSONDecodeError:
            pass

    # 가장 바깥 { ... }
    m = re.search(r'\{[\s\S]*\}', text)
    if m:
        try:
            return json.loads(m.group())
        except json.JSONDecodeError:
            pass

    # [ ... ]
    m = re.search(r'\[[\s\S]*\]', text)
    if m:
        try:
            return json.loads(m.group())
        except json.JSONDecodeError:
            pass

    return None


# ═══════════════════════════════════════════
# 핵심 동작: find_and_click / read_screen
# ═══════════════════════════════════════════

def find_and_click(description, save_debug=False):
    """화면에서 요소를 찾아 클릭한다.

    1. 识货 앱 창만 캡처
    2. Claude에게 좌표 질문 (이미지 내 픽셀 좌표)
    3. 이미지 좌표 → 절대 화면 좌표로 환산
    4. pyautogui.click()

    Returns:
        {"x": int, "y": int} (이미지 내 좌표) 또는 None
    """
    import pyautogui

    img, win = capture_app_window(save_debug=save_debug, label=description[:20])
    if img is None:
        return None

    prompt = f"""이 识货 앱 스크린샷에서 '{description}'의 픽셀 좌표(x, y)를 알려줘.
이미지 왼쪽 상단이 (0, 0)이고, 단위는 이미지 픽셀이다.
클릭해야 할 요소의 중심점 좌표를 알려줘.
반드시 JSON만 응답해: {{"x": 숫자, "y": 숫자}}
요소가 화면에 없으면: {{"x": null, "y": null, "reason": "이유"}}"""

    coords = ask_vision(img, prompt, parse_json=True)
    if not coords or coords.get("x") is None:
        print(f"  [WARN] '{description}' 못 찾음: {coords}")
        return None

    # 이미지 좌표 → 절대 화면 좌표
    abs_x, abs_y = image_coords_to_screen(coords["x"], coords["y"], win)
    pyautogui.click(abs_x, abs_y)
    print(f"  클릭: {description} → 이미지({coords['x']},{coords['y']}) → 화면({abs_x},{abs_y})")
    return coords


def read_screen(prompt, save_debug=False, label=""):
    """앱 창을 캡처하고 AI에게 데이터를 읽게 한다 (클릭 없이).

    Returns:
        파싱된 JSON dict/list 또는 None
    """
    img, _ = capture_app_window(save_debug=save_debug, label=label)
    if img is None:
        return None
    return ask_vision(img, prompt, parse_json=True)


# ═══════════════════════════════════════════
# 텍스트 입력 / 기본 조작
# ═══════════════════════════════════════════

def type_text(text):
    """클립보드를 통해 텍스트를 입력한다 (한글/중국어 안전)."""
    subprocess.run(['pbcopy'], input=text.encode('utf-8'), check=True)
    time.sleep(0.1)
    import pyautogui
    pyautogui.hotkey('command', 'v')
    time.sleep(0.3)


def clear_input():
    """입력 필드 내용을 전부 지운다."""
    import pyautogui
    pyautogui.hotkey('command', 'a')
    time.sleep(0.1)
    pyautogui.press('backspace')
    time.sleep(0.2)


def scroll_right_on_size_bar():
    """사이즈 바 영역에서 왼쪽으로 드래그 → 오른쪽 사이즈 노출."""
    import pyautogui

    win = get_window_info()
    if not win:
        return

    # AI에게 사이즈 바 위치를 물어보는 대신,
    # 스크린샷으로 사이즈 바 위치를 AI에게 묻는다
    img, _ = capture_app_window()
    if img is None:
        return

    bar_info = ask_vision(img, """이 화면에서 사이즈 바(사이즈 목록이 나열된 가로 스크롤 영역)의
이미지 내 중심 y좌표와 오른쪽 끝 x좌표를 알려줘.
JSON만 응답: {"center_y": 숫자, "right_x": 숫자}""", parse_json=True)

    if bar_info and bar_info.get("center_y"):
        scale = get_retina_scale()
        bar_center_y = win["y"] + int(bar_info["center_y"] / scale)
        bar_right_x = win["y"] + int(bar_info.get("right_x", img.width * 0.8) / scale)
        # 사이즈 바 오른쪽에서 왼쪽으로 드래그
        drag_start_x = win["x"] + int(win["width"] * 0.8)
        pyautogui.moveTo(drag_start_x, bar_center_y)
        time.sleep(0.1)
        pyautogui.drag(-250, 0, duration=0.5)
    else:
        # 폴백: 창 중앙 근처에서 드래그
        bar_x = win["x"] + int(win["width"] * 0.75)
        bar_y = win["y"] + int(win["height"] * 0.55)
        pyautogui.moveTo(bar_x, bar_y)
        time.sleep(0.1)
        pyautogui.drag(-250, 0, duration=0.5)

    time.sleep(WAIT_SHORT)


def scroll_down_in_app():
    """앱 내에서 아래로 스크롤한다."""
    import pyautogui

    win = get_window_info()
    if not win:
        return

    center_x = win["x"] + win["width"] // 2
    center_y = win["y"] + win["height"] // 2
    pyautogui.moveTo(center_x, center_y)
    time.sleep(0.1)
    pyautogui.scroll(-5)
    time.sleep(WAIT_MEDIUM)


# ═══════════════════════════════════════════
# 수집 Step 1: 검색 → 상품 상세 진입
# ═══════════════════════════════════════════

def search_product(model):
    """识货에서 모델번호로 검색하고 상품 상세에 진입한다.

    Returns:
        result dict (기본 정보 포함)
    """
    result = {
        "model_no": model.upper(),
        "app": "识货",
        "brand": None,
        "product_name": None,
        "color": None,
        "price_cny": None,
        "size_stock": {},
        "prices": [],
        "sellers": [],
        "spec": {},
        "collected_at": datetime.now().isoformat(),
        "error": None,
    }

    try:
        print(f"\n{'='*50}")
        print(f"  识货 AI 비전 수집: {model}")
        print(f"{'='*50}")

        # 1) 앱 활성화
        activate_app()
        print("\n  [1/7] 앱 활성화 완료")

        # 2) 왼쪽 상단 검색바 클릭 (识货 로고 아래, 搜索 버튼 왼쪽의 입력 필드)
        #    → 이걸 클릭하면 오른쪽에 검색 패널이 열린다
        time.sleep(0.5)
        clicked = find_and_click(
            "왼쪽 패널 상단의 검색 입력 필드 (识货 로고 아래에 있고, 搜索 버튼 왼쪽에 있는 텍스트 입력창)"
        )
        if not clicked:
            result["error"] = "왼쪽 검색바를 찾을 수 없음"
            return result
        time.sleep(WAIT_MEDIUM)
        print("  [2/7] 왼쪽 검색바 클릭 → 오른쪽 검색 패널 열림")

        # 3) 오른쪽 검색 패널에 새로 나타난 검색 입력창 클릭
        #    왼쪽 검색바를 클릭하면 오른쪽에 검색 패널이 열리면서
        #    오른쪽 상단에 새 검색 입력창이 활성화된다
        clicked = find_and_click(
            "오른쪽 패널 상단의 검색 입력창 (방금 열린 검색 패널의 텍스트 입력 필드, 历史搜索 위에 있음)"
        )
        if not clicked:
            # 오른쪽 입력창을 못 찾으면, 이미 포커스가 가 있을 수 있음 → 바로 입력 시도
            print("  [WARN] 오른쪽 검색창 별도 클릭 스킵 (이미 활성화됐을 수 있음)")
        time.sleep(WAIT_SHORT)
        print("  [3/7] 오른쪽 검색 입력창 활성화")

        # 4) 모델번호 입력
        clear_input()
        type_text(model)
        print(f"  [4/7] 모델번호 입력: {model}")

        # 5) Enter 또는 搜索 클릭으로 검색 실행
        time.sleep(0.5)
        import pyautogui
        pyautogui.press('enter')
        time.sleep(WAIT_LONG)
        print("  [5/7] 검색 실행 (Enter)")

        # 6) 첫 번째 검색 결과 클릭
        clicked = find_and_click("검색 결과에서 첫 번째 상품 카드 (이미지+상품명이 보이는 영역)")
        if not clicked:
            result["error"] = "검색 결과를 찾을 수 없음"
            return result
        time.sleep(WAIT_LONG)
        print("  [6/7] 첫 번째 결과 클릭")

        # 7) 상세 페이지에서 기본 정보 읽기
        info = read_screen("""이 识货 앱의 상품 상세 화면을 분석해줘.
다음 정보를 JSON으로 반환:
{
  "product_name": "상품명 (중국어 원문 그대로)",
  "brand": "브랜드명",
  "model_no": "货号/품번 (보이면)",
  "color": "컬러명 (보이면)",
  "lowest_price": 최저가격(숫자만, ¥ 제외),
  "source": "최저가 출처 상점명"
}
정보를 찾을 수 없으면 해당 필드를 null로.""", label="product_detail")

        if info:
            result["product_name"] = info.get("product_name")
            result["brand"] = info.get("brand")
            result["color"] = info.get("color")
            if info.get("model_no"):
                result["model_no"] = info["model_no"]
            result["price_cny"] = info.get("lowest_price")
            print(f"  [7/7] 상품 정보 읽기 완료")
            print(f"         상품명: {info.get('product_name')}")
            print(f"         브랜드: {info.get('brand')}")
            print(f"         최저가: ¥{info.get('lowest_price')}")
        else:
            print("  [7/7] 상품 정보 읽기 (일부 실패)")

    except Exception as e:
        result["error"] = str(e)
        print(f"  [ERROR] {e}")

    return result


# ═══════════════════════════════════════════
# 수집 Step 2: 사이즈별 가격
# ═══════════════════════════════════════════

def collect_sizes(result):
    """사이즈 바에서 모든 사이즈와 가격을 수집한다."""
    print("\n  === 사이즈별 가격 수집 ===")

    all_sizes = {}
    scroll_count = 0
    max_scrolls = 5
    prev_count = -1

    while scroll_count <= max_scrolls:
        sizes_data = read_screen("""이 识货 앱 화면에서 사이즈 바를 찾아 분석해줘.
사이즈 바는 가로로 나열된 사이즈 목록이고, 각 사이즈 아래 또는 옆에 가격(¥)이 있다.

모든 보이는 사이즈와 가격을 추출해.
- 缺货(품절)이면 price를 null로
- 오른쪽에 더 많은 사이즈가 잘려서 안 보이는지 판단해

JSON만 응답:
{
  "sizes": [{"size": "38", "price": 314}, {"size": "39.5", "price": null}],
  "has_more_right": true
}""", label=f"sizes_{scroll_count}")

        if not sizes_data or not isinstance(sizes_data, dict):
            break

        new_found = 0
        for s in sizes_data.get("sizes", []):
            size_key = str(s.get("size", "")).strip()
            if size_key and size_key not in all_sizes:
                all_sizes[size_key] = s.get("price")
                price_str = f"¥{s['price']}" if s.get("price") is not None else "품절"
                print(f"    {size_key}: {price_str}")
                new_found += 1

        # 더 이상 새 사이즈가 없거나, has_more_right가 false면 중단
        if not sizes_data.get("has_more_right", False):
            break

        if new_found == 0 and len(all_sizes) == prev_count:
            break  # 스크롤해도 새 사이즈 없음

        prev_count = len(all_sizes)
        print("    → 사이즈 바 오른쪽 스크롤...")
        scroll_right_on_size_bar()
        scroll_count += 1

    result["size_stock"] = all_sizes

    # 최저가 업데이트
    valid_prices = [p for p in all_sizes.values() if p is not None]
    if valid_prices:
        result["price_cny"] = min(valid_prices)

    sold_out = sum(1 for v in all_sizes.values() if v is None)
    print(f"\n    총 {len(all_sizes)}개 사이즈 수집 (품절 {sold_out}개)")


# ═══════════════════════════════════════════
# 수집 Step 3: 판매처 리스트
# ═══════════════════════════════════════════

def collect_sellers(result):
    """查看全网底价 화면에서 판매처 리스트를 수집한다."""
    print("\n  === 판매처 수집 ===")

    # 查看全网底价 버튼 클릭
    clicked = find_and_click("查看全网底价 빨간색 버튼 (화면 하단)")
    if not clicked:
        # 스크롤 다운 후 재시도
        print("  → 하단 버튼 안 보임, 스크롤 후 재시도...")
        scroll_down_in_app()
        clicked = find_and_click("查看全网底价 빨간색 버튼")
        if not clicked:
            print("  [WARN] 查看全网底价 버튼을 찾을 수 없음")
            return

    time.sleep(WAIT_LONG)

    # 판매처 리스트를 읽는다 (스크롤하며 여러 번)
    all_sellers = []
    seen_shops = set()
    scroll_count = 0
    max_seller_scrolls = 3

    while scroll_count <= max_seller_scrolls:
        sellers_data = read_screen("""이 识货 앱의 전체최저가(查看全网底价) 화면에서 보이는 모든 판매처를 분석해줘.

각 판매처에서 추출할 정보:
- shop: 상점명
- platform: 플랫폼 (得物/天猫/淘宝/京东/识货 등)
- price: 가격 (숫자만)
- trust: 신뢰 가능 여부 (boolean)
- trust_reason: 신뢰 판별 근거

신뢰 가능 기준:
- 得物 (得物, 得物-品牌官方 포함) → trust: true, reason: "得物"
- 상점명 옆에 品牌官方 표시 → trust: true, reason: "品牌官方"
- 상점명에 官方旗舰店 또는 旗舰店 포함 → trust: true, reason: "旗舰店"
- 상점명에 专营店 포함 → trust: true, reason: "专营店"
- 그 외 → trust: false, reason: "일반 상점"

아래로 스크롤하면 더 있는지도 판단해.

JSON만 응답:
{
  "sellers": [
    {"shop": "得物", "platform": "得物", "price": 314, "trust": true, "trust_reason": "得物"}
  ],
  "has_more_below": false
}""", label=f"sellers_{scroll_count}")

        if not sellers_data or not isinstance(sellers_data, dict):
            break

        for s in sellers_data.get("sellers", []):
            shop_key = f"{s.get('shop','')}_{s.get('platform','')}"
            if shop_key not in seen_shops:
                seen_shops.add(shop_key)
                all_sellers.append(s)
                tag = "✓" if s.get("trust") else "✗"
                print(f"    {tag} {s.get('shop','')} ({s.get('platform','')}) ¥{s.get('price','?')} [{s.get('trust_reason','')}]")

        if not sellers_data.get("has_more_below", False):
            break

        scroll_down_in_app()
        scroll_count += 1

    # result에 추가
    now = datetime.now().isoformat()
    for s in all_sellers:
        result["prices"].append({
            "size": None,  # 전체 사이즈 대표가
            "price_cny": s.get("price"),
            "shop_name": s.get("shop", ""),
            "platform": s.get("platform", ""),
            "trust_level": s.get("trust_reason", ""),
            "trusted": s.get("trust", False),
            "collected_at": now,
        })

    result["sellers"] = all_sellers

    trusted = [s for s in all_sellers if s.get("trust")]
    print(f"\n    총 {len(all_sellers)}개 판매처 (신뢰: {len(trusted)}개)")

    # 뒤로가기 (상세 화면으로 복귀)
    _go_back()


def _go_back():
    """뒤로가기 — 识货 앱에서 이전 화면으로 돌아간다."""
    # 왼쪽 상단 뒤로가기 버튼 클릭 시도
    clicked = find_and_click("왼쪽 상단의 뒤로가기 버튼 (< 또는 화살표 아이콘)")
    if not clicked:
        import pyautogui
        pyautogui.press('escape')
    time.sleep(WAIT_MEDIUM)


# ═══════════════════════════════════════════
# 수집 Step 4: 상품 스펙 (产品参数)
# ═══════════════════════════════════════════

def collect_spec(result):
    """상품 스펙(产品参数)을 수집한다."""
    print("\n  === 상품 스펙 수집 ===")

    # 스크롤 다운해서 产品参数 영역 노출
    scroll_down_in_app()
    time.sleep(WAIT_SHORT)

    # 产品参数 영역 또는 스펙 바를 찾아서 클릭
    clicked = find_and_click("产品参数 또는 제품 스펙 영역 (货号/品牌 등이 나열된 바)")
    time.sleep(WAIT_MEDIUM)

    # 모달이든 화면이든 현재 보이는 스펙 정보를 읽는다
    spec_data = read_screen("""이 화면에서 상품 스펙(产品参数) 정보를 모두 읽어줘.
보이는 모든 필드를 중국어 키 그대로 JSON으로 반환해.

예시:
{
  "货号": "ID6016",
  "品牌": "adidas/阿迪达斯",
  "鞋面材质": "合成革",
  "鞋底材料": "橡胶",
  "闭合方式": "系带",
  "鞋帮高度": "低帮"
}

产品参数 모달이나 영역이 안 보이면: {"error": "not_found"}""",
                             label="spec")

    if spec_data and isinstance(spec_data, dict) and "error" not in spec_data:
        result["spec"] = spec_data
        for k, v in spec_data.items():
            print(f"    {k}: {v}")

        # 货号로 모델번호 교차 확인
        huohao = spec_data.get("货号", "")
        if huohao and huohao.upper() != result["model_no"].upper():
            print(f"  [WARN] 货号 불일치! 입력: {result['model_no']}, 识货: {huohao}")
    else:
        print("    스펙 정보를 찾을 수 없음 (스크롤 더 필요할 수 있음)")

    # 모달이 열렸으면 닫기
    find_and_click("X 닫기 버튼 (모달 오른쪽 상단)")
    time.sleep(WAIT_SHORT)


# ═══════════════════════════════════════════
# 전체 수집 흐름
# ═══════════════════════════════════════════

def collect_full(model):
    """전체 수집: 검색 → 기본정보 → 사이즈 → 스펙 → 판매처"""
    result = search_product(model)
    if result.get("error"):
        save_result(result)
        return result

    collect_sizes(result)
    collect_spec(result)
    collect_sellers(result)

    # 수집 시각 갱신
    result["collected_at"] = datetime.now().isoformat()

    save_result(result)
    return result


# ═══════════════════════════════════════════
# 결과 저장
# ═══════════════════════════════════════════

def save_result(result):
    """수집 결과를 JSON 파일로 저장하고 요약을 출력한다."""
    RESULTS_DIR.mkdir(exist_ok=True)
    model = result.get("model_no", "unknown").replace("/", "_")
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = RESULTS_DIR / f"{model}_{ts}.json"

    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"\n  결과 저장: {path}")
    print(f"\n  {'='*40}")
    print(f"  수집 요약")
    print(f"  {'='*40}")
    print(f"  모델번호: {result.get('model_no')}")
    print(f"  브랜드:   {result.get('brand', '?')}")
    print(f"  상품명:   {result.get('product_name', '?')}")
    print(f"  컬러:     {result.get('color', '?')}")
    print(f"  최저가:   ¥{result.get('price_cny', '?')}")

    sz = result.get("size_stock", {})
    sold_out = sum(1 for v in sz.values() if v is None)
    print(f"  사이즈:   {len(sz)}개 (품절 {sold_out}개)")

    sellers = result.get("sellers", [])
    trusted = [s for s in sellers if s.get("trust")]
    print(f"  판매처:   {len(sellers)}개 (신뢰 {len(trusted)}개)")

    if result.get("spec"):
        print(f"  스펙:     {len(result['spec'])}개 항목")

    if result.get("error"):
        print(f"  오류:     {result['error']}")


# ═══════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="识货 앱 가격 수집 (AI 비전)")
    parser.add_argument("--model", help="모델번호 (예: ID6016)")
    parser.add_argument("--full", action="store_true",
                        help="전체 수집 (사이즈+판매처+스펙)")
    parser.add_argument("--check", action="store_true",
                        help="사전 요건 체크")
    parser.add_argument("--debug", action="store_true",
                        help="디버그 스크린샷 저장")
    args = parser.parse_args()

    if args.check:
        check_prerequisites()
        return

    if not args.model:
        print("识货 앱 가격 수집 (AI 비전 방식)")
        print()
        print("사용법:")
        print("  python3 china_price.py --check                  # 사전 요건 체크")
        print("  python3 china_price.py --model ID6016            # 빠른 검색")
        print("  python3 china_price.py --model ID6016 --full     # 전체 수집")
        print("  python3 china_price.py --model ID6016 --full --debug  # 디버그 모드")
        print()
        print("사전 설정:")
        print("  1. pip3 install anthropic pyautogui pillow")
        print("  2. export ANTHROPIC_API_KEY=\"sk-ant-...\"")
        print("  3. 시스템 설정 > 화면 녹화 > Terminal 허용")
        print("  4. 识货 앱 열기")
        return

    # 사전 검증
    if not _test_screenshot():
        print("[ERROR] 화면 녹화 권한이 없습니다.")
        print("시스템 설정 > 개인정보 보호 > 화면 녹화 > Terminal 허용")
        return

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("[ERROR] ANTHROPIC_API_KEY가 설정되지 않았습니다.")
        print("export ANTHROPIC_API_KEY=\"sk-ant-...\"")
        return

    # pyautogui 안전 설정
    import pyautogui
    pyautogui.FAILSAFE = True
    pyautogui.PAUSE = 0.1

    # 실행
    if args.full:
        result = collect_full(args.model)
    else:
        result = search_product(args.model)
        save_result(result)

    # 최종 JSON 출력
    print("\n" + json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
