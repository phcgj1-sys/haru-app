window.SUM_DATA=window.SUM_DATA||{};
window.SUM_DATA["script"]={
 slug:"script",
 title:"쉘 스크립트와 서버 자동화",
 one:"슬랙웨어 15.0(bash 5.1) 서버에서 클로드가 써 준 스크립트를 검토·시험해 cron(예약표)에 안전하게 등록하는 법이에요.",
 must:[
  ["안전한 머리 다섯 줄","tools 첫 칸의 다섯 줄로 모든 스크립트를 시작해요(set -u: 빈 변수면 멈춤, pipefail: 파이프 중간 실패도 실패, PATH(명령 찾는 폴더 목록) 줄)."],
  ["변수는 언제나 \"$VAR\"","큰따옴표로 감싸고, 지우는 경로는 \"${DIR:?}\" 로 빈 변수를 막아요."],
  ["바꾸기 전 드라이런","바꾸는 명령은 먼저 echo·-print·--dry-run 으로 보고, cp 날짜 백업 뒤 실행해요."],
  ["systemd 없는 서버","systemctl·journalctl·apt 는 없어요. 서비스는 /etc/rc.d/rc.이름, 예약은 dcron."],
  ["비밀은 파일에, chmod 600","봇 토큰은 /root/.telegram.env, DB 암호는 /root/.my.cnf 에 두고 잠가요."],
  ["등록 순서","검토 → bash -n → 드라이런 → 연습 서버 → 운영에서 손으로 1번 → cron. 점검표에 빈칸이 하나라도 있으면 등록하지 않고, 큰 스크립트는 점검 버전부터 한 단계씩 키워요."]
 ],
 stages:[
  {t:"1단계 · 쉘과 첫 스크립트",pts:[
   ["쉘(shell, 명령 접수 창구)은 bash 5.1, 스크립트는 매일 치던 명령을 묶은 파일이에요.","l01"],
   ["첫 줄 #!/bin/bash(셔뱅), /root/bin 에 확장자 없이 저장, chmod +x 뒤 전체 경로로 실행해요.","l02"],
   ["NAME=\"PSL-MA\" 처럼 = 앞뒤 띄어쓰기 없이. 큰따옴표 안은 값으로 풀리고 작은따옴표 안은 글자 그대로, 붙여 쓸 땐 \"${NAME}_old\".","l03"],
   ["$(명령)은 결과를 담고(TODAY=\"$(date +%F)\"), | 는 넘기기, > 는 덮어쓰기, >> 는 덧붙이기(기록엔 항상 >>), 2>&1 은 오류도 같이, > /dev/null 은 버리기.","l04"],
   ["백업은 cp -p 파일 파일.bak-$(date +%F), 시험은 테스트 서버에서.","l05"]
  ]},
  {t:"2단계 · 조건과 반복",pts:[
   ["if [ 조건 ]; then ... fi — 대괄호 안쪽 앞뒤 한 칸. -f 파일, -d 폴더, -z 빈 값, -n 값 있음, 숫자는 -gt·-lt·-ge·-eq, 글자는 = · !=. [ \"$(hostname)\" != \"서버이름\" ] 면 exit 1 로 엉뚱한 서버에서 도는 걸 막아요.","l06"],
   ["종료 코드 0 = 성공, 그 밖은 실패(바로 다음 줄 echo $?). A && B(성공하면), A || B(실패하면), 스크립트 끝은 exit 0/1.","l07"],
   ["for X in 목록; do ... done, 파일은 while IFS= read -r LINE; do ... done < 파일 로 한 줄씩. i=$((i+1)) 을 빼면 무한 반복.","l08"],
   ["log() { echo \"$(date '+%F %T') $*\" >> \"$LOG\"; } 처럼 함수를 위쪽에 먼저 적어요. 알림은 notify 함수로 따로 둬요.","l09"],
   ["인자는 $1·$2, 개수 $#, 전부 \"$@\". 모자라면 usage 보여 주고 exit 1, 기본값은 ${1:-/var/log}.","l10"]
  ]},
  {t:"3단계 · 텍스트 다루기",pts:[
   ["grep -i(대소문자 무시)·-n(줄 번호)·-c(개수)·-v(없는 줄)·-E 'a|b'(또는)·-q(if 용).","l11"],
   ["awk '{print $5}' 는 5번째 칸, NR>1 은 제목 줄 빼기, -F: 는 : 로 나누기, $NF 는 마지막 칸. 꼭 작은따옴표로 감싸요.","l12"],
   ["sed 's/옛/새/g' 는 결과만 화면에 보여 주고 파일은 그대로라 먼저 미리 보기로 써요. 파일을 바꿀 땐 sed -i.bak 로 백업하고, 설정 파일이면 바꾼 뒤 apachectl -t 로 문법 검사해요. 줄 끝 CR(^M) 제거는 tools 참고.","l13"],
   ["많이 나온 것 상위 10개는 sort | uniq -c | sort -rn | head -n 10. wc -l 은 줄 수, tail -f 는 새 줄 계속 보기.","l14"],
   ["date +%F(2026-11-22 모양), date -d 'yesterday' +%F. syslog 오늘 줄은 LC_ALL=C date '+%b %e' 로 맞춰요(%e 는 한 자리 날짜 앞 공백).","l15"]
  ]},
  {t:"4단계 · 점검 스크립트 만들기",pts:[
   ["check-disk: df -P 다섯째 칸(사용률)이 LIMIT=80 이상인 자리(여섯째 칸)만 골라 경고, 종료 코드 1. 공간 없음이면 df -Pi. 경고가 나면 du -xh --max-depth=1 /자리 | sort -h 로 큰 폴더를 봐요.","l16"],
   ["check-svc: pgrep -x 이름(찾으면 0, 못 찾으면 1), 이름은 ps -eo comm | sort -u 로 확인, DB 는 mysqladmin ping. 재시작은 알림 몇 주 뒤에, 로그 먼저·하루 횟수 제한(예: 3번), sshd 는 제외.","l17"],
   ["check-log: 오늘 syslog 줄 수, messages·secure 의 'Failed password' 수와 실패 IP 상위. 0개여도 grep -c 는 0 을 찍고 코드 1. 일주일 >> 로 쌓아 평소 숫자를 보고 기준값을 정해요.","l18"],
   ["daily-report: uptime·free·df·pgrep·로그 수를 { ... } > /root/reports/health-$(date +%F).txt 로 모아 어제와 diff(두 파일 비교).","l19"],
   ["텔레그램: BotFather(봇 만드는 공식 봇)로 토큰, getUpdates 로 chat id(받는 방 번호). 토큰 파일을 . 으로 불러 curl sendMessage, 약 4096자 한도(바뀔 수 있어요)라 4000자로 잘라요. 토큰이 새면 /revoke 로 새로 받아 파일만 바꿔요.","l20"]
  ]},
  {t:"5단계 · 자동 실행과 운영",pts:[
   ["크론 줄은 '분 시 일 월 요일 명령'(*/10 = 10마다). crontab -l > 백업 → crontab -e → crontab -l 확인(되돌리기: crontab 백업파일). 하루 한 번이면 /etc/cron.daily 에 넣어도 돼요(이름에 점 금지).","l21"],
   ["cron 에서만 'command not found' 는 짧은 PATH 탓: 맨 위 PATH, 전체 경로, >> 로그 2>&1. 확인은 내 로그·/var/spool/mail/root(기본 -l notice 면 /var/log/cron 에 실행 줄 없음, -l info 로 보임).","l22"],
   ["백업: tar -czf 로 웹, mysqldump --all-databases --single-transaction 으로 DB. rsync 는 --dry-run 먼저, --delete 는 처음엔 금지. tar -tzf 로 복원 시험, 다른 서버·NAS 로 복사.","l23"],
   ["정리: find ... -mtime +14 -print 로 먼저 보고 -delete 는 맨 끝에. 시스템 로그는 logrotate(로그 돌려 쓰기) 몫이니 내 로그는 /etc/logrotate.d/myscripts 에 맡기고 logrotate -d 로 미리 봐요.","l24"],
   ["겹침: exec 9>/var/lock/이름.lock; flock -n 9 || exit 0 . timeout 60 명령 은 넘으면 끊고 종료 코드 124.","l25"]
  ]},
  {t:"6단계 · 클로드와 함께 자동화",pts:[
   ["요청 글 다섯 칸: 환경(슬랙웨어 15.0, systemd 없음, root, dcron)·목적·입력·출력·금지(systemctl·apt·rm -rf 금지, 토큰은 파일, DRY_RUN=1 이면 echo 만). 한국어 주석·시험 방법도 받아요.","l26"],
   ["검토: grep -nE 로 위험 낱말(rm -rf, mkfs, dd, --delete, -delete, chmod -R, reboot, curl | sh) 줄 확인 → bash -n(문법만, 뜻은 별개) → 따옴표·빈 변수 확인(순서는 must 참고).","l27"],
   ["bash -x 는 + 줄로 실제 명령을 보여요(지우는 건 DRY_RUN=1). 오류: command not found→PATH, Permission denied→chmod +x, No such file→경로·CR, unexpected end of file→fi·done 빠짐, [: missing ]→] 앞 띄어쓰기, unbound variable→빈 변수, bad interpreter→CR.","l28"],
   ["/root/bin 에 모으고 머리 주석과 README(바꾼 날짜·이유)를 적어요. 고치기 전 cp 날짜 백업, /root/bin 도 tar 백업(비밀 파일 둘은 빼요).","l29"],
   ["실전 5과제(디스크·서비스·백업·아침 요약·인증서 openssl x509 -enddate -noout)마다 목표·명령·검증을 채우고, 기준값을 바꿔 경고를 확인한 뒤 되돌려요. 서비스 감시는 연습 서버에서만 멈춰 보고, 운영 서버·sshd 는 멈추지 않아요.","l30"]
  ]}
 ],
 tools:[
  ["안전한 머리","#!/bin/bash\n# [이름] - [하는 일] ([만든 날짜])\nset -u\nset -o pipefail\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/usr/sbin:/bin:/usr/bin","모든 스크립트 첫 다섯 줄"],
  ["로그인 실패 IP 상위 10","grep -h 'Failed password' /var/log/messages /var/log/secure | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -n 10","누가 자꾸 실패하나 볼 때"],
  ["크론 줄 예시","*/10 * * * * /root/bin/check-disk >> /var/log/check-disk.log 2>&1\n30 7 * * * /root/bin/daily-report >> /var/log/daily-report.log 2>&1","crontab -e 에 한 줄씩"],
  ["잠금 두 줄","exec 9>/var/lock/daily-backup.lock\nflock -n 9 || { echo \"이미 실행 중\"; exit 0; }","겹쳐 도는 것 막기"],
  ["오래된 파일 보기 → 지우기","find /backup -type f -name '*.gz' -mtime +14 -print\nfind /backup -type f -name '*.gz' -mtime +14 -print -delete","둘째 줄은 목록 확인 뒤에만"],
  ["받은 스크립트 검토","grep -nE 'rm -rf|mkfs|dd |--delete|-delete|chmod -R|chown -R|reboot|shutdown|> /dev/sd|curl.*\\| *(ba)?sh' /root/bin/[스크립트]\nbash -n /root/bin/[스크립트] && echo \"문법 통과\"","등록 전 검토"],
  ["줄 끝 CR 확인·제거","cat -A /root/bin/[스크립트] | head -n 3\nsed -i.bak 's/\\r$//' /root/bin/[스크립트]","^M$ 가 보일 때만"]
 ],
 mistakes:[
  ["find 에 -delete 를 앞쪽에 씀","-print 로 목록 먼저 보고, -delete 는 맨 끝에만 붙여요."],
  ["sort 없이 uniq -c 로 셈","uniq 는 붙어 있는 같은 줄만 세니 앞에 꼭 sort, 순서는 sort | uniq -c | sort -rn."],
  ["로그·설정을 그대로 클로드에게 붙임","비밀번호·봇 토큰·chat id·공인 IP 끝자리·고객 이름·전화번호는 [가림]으로 지우고, .telegram.env·.my.cnf 내용은 보여 주지 않아요."]
 ]
};
