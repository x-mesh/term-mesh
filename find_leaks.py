import os
import re

sources_dir = 'Sources'
results = []

delegate_regex = re.compile(r'^\s*(?:@objc\s+)?(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(?:lazy\s+)?var\s+\w*(?:[dD]elegate|[dD]ataSource)\s*:\s*[A-Z\[]', re.MULTILINE)

timer_regex = re.compile(r'(?:Timer\.scheduledTimer|DispatchSource\.[a-zA-Z0-9_]+)[^{]*\{([^}]*)\}')
notification_regex = re.compile(r'NotificationCenter\.default\.addObserver[^{]*\{([^}]*)\}')
dispatch_regex = re.compile(r'DispatchQueue\.[^{]*\{([^}]*)\}')

def analyze_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return
    
    lines = content.split('\n')
    
    # 1. Delegate (missing weak)
    for i, line in enumerate(lines):
        if delegate_regex.search(line):
            if 'weak ' not in line and 'unowned ' not in line:
                results.append((filepath, i+1, "Delegate without weak", "High", line.strip()[:100]))
    
    def check_blocks(regex, name, severity):
        for match in regex.finditer(content):
            block_start = match.start(1)
            # Find the closing brace of this block
            brace_count = 1
            block_end = block_start
            while block_end < len(content) and brace_count > 0:
                if content[block_end] == '{':
                    brace_count += 1
                elif content[block_end] == '}':
                    brace_count -= 1
                block_end += 1
            
            block = content[block_start:block_end]
            
            if re.search(r'\bself\b', block):
                # Check for [weak self] or [unowned self]
                header_match = re.match(r'\s*\[([^\]]+)\]', block)
                has_weak_self = False
                if header_match:
                    cap_list = header_match.group(1)
                    if 'weak self' in cap_list or 'unowned self' in cap_list:
                        has_weak_self = True
                
                if not has_weak_self:
                    start_index = match.start()
                    line_num = content.count('\n', 0, start_index) + 1
                    snippet = lines[line_num-1].strip()[:100]
                    # We might want to see if it's a known non-escaping closure, 
                    # DispatchQueue async is escaping, Timer is escaping.
                    results.append((filepath, line_num, name, severity, snippet))

    check_blocks(timer_regex, "Timer Strong Capture", "High")
    check_blocks(notification_regex, "NotificationCenter Strong Capture", "High")
    check_blocks(dispatch_regex, "DispatchQueue Strong Capture", "Medium")

for root, _, files in os.walk(sources_dir):
    for file in files:
        if file.endswith('.swift'):
            analyze_file(os.path.join(root, file))

results.sort(key=lambda x: (x[0], x[1]))
print("| 파일명 | 라인번호 | 패턴 종류 | 위험도 | 코드 스니펫 |")
print("|---|---|---|---|---|")
for r in results:
    print(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | `{r[4]}` |")
