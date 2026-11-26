window.SUM_DATA=window.SUM_DATA||{};
window.SUM_DATA["linux"]={
 slug:"linux",
 title:"리눅스 서버 장애 판별",
 one:"슬랙웨어 15.0 서버 장애를 8종으로 가르고, 읽기 전용 명령으로 먼저 보고 기록한 뒤 고치는 법이에요.",
 must:[
  ["먼저 보고, 나중에 고친다","재시작·삭제는 증거를 지워요. 읽기 전용 명령부터 쳐요."],
  ["root(최고 관리자)는 치는 순간 적용","바꾸는 명령은 한 번 더 읽고, 뜻을 모르면 클로드에게 이유와 되돌리는 법부터 물어요."],
  ["systemd 없는 서버","systemctl·journalctl·apt·ufw·timedatectl 은 없어요. 서비스는 /etc/rc.d/rc.이름, 로그는 /var/log 와 dmesg(커널 메시지)예요."],
  ["바꾸기 전 검사·사본·콘솔","재시작 전 설정 검사(apachectl configtest·sshd -t), 고치기 전 cp 로 사본, 끊길 일은 콘솔 확보 뒤 해요."],
  ["클로드엔 환경 줄 먼저","첫 줄에 '슬랙웨어 15.0, systemd 없음, root 작업'을 적어요. 빼면 없는 명령을 받아요."]
 ],
 stages:[
  {t:"1단계 · 장애의 지도와 안전 수칙",pts:[
   ["장애는 8종(접속 불가, 느림, 서비스 죽음, 디스크 꽉 참, 메모리 부족, 네트워크·DNS, 보안 침해, 부팅 실패)이에요. 증상이 겹치면 디스크(df -h)부터 봐요.","l01"],
   ["기록하고 한 번에 하나만 바꿔요. 뜻 모르면 절대 금지: rm -rf /, mkfs, chmod -R 777 /, 콘솔 없이 reboot, curl ... | bash.","l02,l03"],
   ["프롬프트 끝 # 는 root 라 sudo 는 빼고 쳐요. 부팅 때 켜지는 서비스는 x(실행 권한)가 있는 rc 스크립트, 설치 목록은 /var/lib/pkgtools/packages 예요.","l03,l04"],
   ["종류를 모를 땐 5분 건강 점검부터 하고, 하루 한 번 기준선을 저장해 diff 로 비교해요.","l05"]
  ]},
  {t:"2단계 · 로그와 서비스 읽기",pts:[
   ["syslog 는 경고 이상(장애 때 먼저), messages 는 일반 정보, secure 는 PAM 인증·login·su 예요(sshd 의 Failed password·Accepted 는 messages 라 둘 다 봐요). 시각은 grep 'Nov  9 09:' 로 자르고(한 자리 날짜는 공백 두 개), .gz 는 zcat 으로 읽어요.","l06"],
   ["dmesg -T 의 Killed process 는 메모리 부족, I/O error·remount 는 디스크, link is down 은 네트워크 신호예요. 시각이 이상하면 서버 시간(date)부터 봐요.","l07"],
   ["rc 파일에 x 가 있는데 프로세스가 없으면 부팅 뒤 죽은 것, x 가 없는데 돌면 손으로 켠 것이라 재부팅하면 사라져요.","l08"],
   ["클로드엔 장애 전후 50~100줄만, 비밀번호·토큰·공인 IP·고객 정보는 지우고 넘겨요. 장애 중엔 명령마다 시각·명령·결과 한 줄, 끝나면 포스트모템(장애 보고서) 8칸을 써요.","l09,l10"],
   ["다른 배포판 명령은 없으니 바꿔 읽어요: systemctl restart → rc.이름 restart, enable → chmod +x, apt → slackpkg.","l31"]
  ]},
  {t:"3단계 · 자원 장애: CPU·메모리·디스크",pts:[
   ["부하 평균(uptime)은 nproc(코어 수)와 비교해요: 코어 4개에 4.0이면 꽉 참, 8.0이면 줄 섬이에요. top 에서 k(끄기)는 누르지 않고, CPU 는 낮은데 %wa(I/O 대기)가 높으면 디스크를 의심해요.","l11"],
   ["free -h 는 available(실제 쓸 수 있는 양)을 봐요. OOM killer(메모리 바닥 때 강제 종료)가 끈 프로그램은 Killed process 뒤 괄호 안 이름이에요.","l12"],
   ["df -h Use% 90% 이상·df -i(아이노드) IUse% 100% 면 꽉 참. No space left 인데 용량이 남았으면 df -i 를 봐요. 큰 폴더는 du 로 한 단계씩, du 합보다 df 가 크면 lsof +L1(지웠는데 잡힌 파일)로 찾아요.","l13"],
   ["iostat -xz 1 5 의 %util(디스크 바쁜 비율) 90% 이상·await(평균 대기) 수백 ms 가 이어지면 병목이에요. smartctl -a 의 Reallocated·Pending(불량 섹터)이 늘면 (PASSED 라도) 교체 신호라 백업부터 해요.","l14"],
   ["lsblk -f 와 /etc/fstab(부팅 때 붙일 목록)의 UUID 를 대조해요. fstab 오타면 복구 셸로 떨어져요. mount -o remount,rw / 뒤 고치고 mount -a 로 확인하고, 외장 디스크엔 nofail(없어도 부팅 계속)을 붙여요.","l15"]
  ]},
  {t:"4단계 · 네트워크·접속·웹 장애",pts:[
   ["접속 불가는 내 인터넷 → ping → nc -zv 서버 22(포트 두드리기) → ssh -v → 콘솔 순서예요. refused 면 sshd 꺼짐, timeout 이면 방화벽·네트워크, 바로 Connection closed 면 /etc/hosts.deny·hosts.allow 를 봐요.","l16"],
   ["게이트웨이는 ip r 의 default via, DNS 는 /etc/resolv.conf, 설정은 /etc/rc.d/rc.inet1.conf 예요. ping 8.8.8.8 은 되고 google.com 이 안 되면 DNS 문제예요.","l17"],
   ["기본 방화벽은 없고, 있다면 관리자가 만든 /etc/rc.d/rc.firewall 이에요. iptables -L -n -v 로 policy(기본 정책, DROP·ACCEPT)부터 봐요.","l18"],
   ["500 은 error_log(앱·PHP), 403 은 권한·Require, 404 는 경로·DocumentRoot, 503 은 과부하·점검, 502/504 는 프록시 뒤 앱이 죽거나 느림, refused 는 httpd 꺼짐이에요. 적용은 configtest 가 Syntax OK 일 때만 rc.httpd graceful(안 끊고 다시 읽기)로 해요.","l19"],
   ["DB 생존은 mysqladmin ping, 소켓 오류는 DB 꺼짐이나 소켓 경로 차이예요. 인증서는 openssl s_client 의 notAfter(만료일)와 crontab -l(예약 작업)의 갱신 줄, 시간은 ntpq -p 의 * 줄(동기 중)을 봐요.","l20"]
  ]},
  {t:"5단계 · 보안·부팅·운영 장애",pts:[
   ["침해 기준은 '내가 모르는 것'(로그인·포트·프로세스·cron·SSH 키·계정·rc 스크립트)이 있나예요. 확실하면 격리 → 보존 → 교체 → 재구축이에요. 예방: PasswordAuthentication no·PermitRootLogin no·hosts.allow 로 ssh IP 제한.","l21"],
   ["slackpkg 패치는 미러 한 줄만 켜고, 도구 모음의 순서대로 해요. 커널은 blacklist 라 upgrade-all 로 안 올라가고, clean-system(SBo·따로 넣은 패키지까지 지움)은 초보는 쓰지 않아요.","l22"],
   ["부팅 실패 1위는 fstab 오타예요. LILO(부트로더)에서 Tab 으로 옛 커널을 고르거나 single(단일 사용자)을 붙이고, 안 되면 설치 USB → mount → bind 마운트 → chroot → lilo 로 고쳐요.","l23"],
   ["cron 은 dcron(오류 출력은 root 메일)이고, /var/log/cron 은 기본 -l notice 라 실행마다 안 남아요(보려면 /etc/default/crond 를 -l info 로). 터미널에선 되는데 안 돌면 전체 경로·환경 변수·실행 권한, crond 가 떠 있나도 봐요.","l24"],
   ["도커(SlackBuilds 로 설치했을 때, rc.docker)는 docker ps -a 의 STATUS → docker logs --tail 100 순서로 보고, 디스크 범인은 컨테이너 로그라 daemon.json 의 log-opts max-size 로 제한해요.","l25"]
  ]},
  {t:"6단계 · 판별 체계와 클로드 활용",pts:[
   ["결정 나무는 증상 → 의심 → 확인 명령 → 조치예요. 앞 세 칸을 채우고 기록한 뒤에만 가장 가벼운 조치로 가요.","l26"],
   ["감시는 cron + bash 스크립트(df 80%·데몬 사라짐 → 텔레그램 curl)로 하고, 통째로 죽을 때를 위해 서버 밖 생존 확인(UptimeRobot 등)을 둬요. 토큰은 chmod 600 파일에 둬요.","l27"],
   ["클로드 답은 which 로 명령이 있나, 바꾸는 명령에 되돌리는 법이 있나 검증해요. 클로드 코드에 ssh 를 맡길 땐 읽기 전용만, 바꾸는 명령은 제안만 하게 해요.","l28"],
   ["재발 방지는 근본 원인에 걸고 변경은 /root/CHANGES.txt 에 적어요. 백업은 월 1회 풀어 봐요. DB 는 restore_test 같은 새 이름에만 풀어요. 모의 훈련은 스냅샷 찍은 연습용 VM(가상 머신)에서만 해요.","l29,l30"]
  ]}
 ],
 tools:[
  ["5분 건강 점검","1) uptime\n2) free -h\n3) df -h\n4) df -i\n5) top (q 나가기, P/M 정렬)\n6) ls -l /etc/rc.d/ | grep '^-rwx'; ps aux | grep -E '[h]ttpd|[m]ysqld|[s]shd|[c]rond|[s]yslogd'\n7) tail -n 30 /var/log/syslog\n8) ss -tulpn\n9) last -n 10; lastb -n 10 (lastb 는 /var/log/btmp 가 있어야 기록)\n10) dmesg -T | tail -n 30","장애 종류를 모를 때"],
  ["기준선 저장·비교","(date; uptime; free -h; df -h; df -i; ss -tlnp; tail -n 30 /var/log/syslog) > /root/health-$(date +%F).txt\ndiff /root/health-[어제].txt /root/health-[오늘].txt","하루 한 번"],
  ["서비스 생존·설정 검사","ps aux | grep -i '[h]ttpd'; ss -tlnp | grep ':80'; tail -n 20 /var/log/httpd/error_log\n(sshd 는 :22·/var/log/messages·secure, mysqld 는 :3306·/var/lib/mysql/호스트명.err)\napachectl configtest; sshd -t; mysqladmin ping","서비스 죽음 의심·재시작 전"],
  ["오류 줄 걸러 보기","tail -n 100 /var/log/syslog\ngrep -iE 'error|fail|oom|killed|denied' /var/log/syslog | tail -n 50\ndmesg -T | grep -iE 'out of memory|killed process|oom'\ndmesg -T | grep -iE 'I/O error|Buffer I/O|ata[0-9]|EXT4-fs error|xfs|remount'\ndmesg -T | grep -iE 'link is down|link up|eth[0-9]'\n(dmesg 세 줄은 메모리·디스크·네트워크. 결과가 비면 그 종류는 일단 아니에요)","원인 찾을 때"],
  ["디스크 범인 찾기","df -h; df -i\ndu -xh --max-depth=1 / 2>/dev/null | sort -h | tail -20\nlsof +L1","No space left 가 뜰 때"],
  ["접속·네트워크 확인","내 PC 에서: ping -c 4 서버주소; nc -zv 서버주소 22; ssh -v root@서버주소\n서버에서: ip a; ip r; cat /etc/resolv.conf\nping -c 4 8.8.8.8; ping -c 4 google.com; dig google.com\nss -tulpn; curl -I http://localhost","접속·DNS 장애 때"],
  ["침해 징후 점검","grep -h 'Failed password' /var/log/messages /var/log/secure | wc -l\ngrep -h 'Accepted' /var/log/messages /var/log/secure | tail\nlast -a | head; lastb | head; w\nss -tulpn\nps aux --sort=-%cpu | head -15\ncrontab -l; cat /var/spool/cron/crontabs/root\ncat /root/.ssh/authorized_keys\nfind / -xdev -mmin -60 -type f 2>/dev/null | head\nawk -F: '$3>=1000' /etc/passwd\nls -l /etc/rc.d/ | grep '^-rwx'; cat /etc/rc.d/rc.local","침해가 의심될 때"],
  ["slackpkg 보안 패치","slackpkg update\nslackpkg check-updates\n(여기부터 바꾸는 명령: 백업·콘솔 확보 뒤)\nslackpkg upgrade-all\nslackpkg new-config\nslackpkg install-new\nls -l /etc/rc.d/*.new; ls /etc/*.new 2>/dev/null","정기 패치 때"],
  ["클로드 붙여넣기 틀","1) 증상: [언제부터 무엇이]\n2) 환경: 슬랙웨어 15.0 x86_64, systemd·journalctl·apt 없음, root 로 작업 중, 역할 [웹/DB/...]\n3) 명령과 출력(그대로): [출력]\n4) 이미 해 본 것: [명령과 결과]\n5) 요청: 슬랙웨어에 있는 읽기 전용 명령부터 알려 주고, systemctl·journalctl·apt 는 쓰지 말고, 바꾸는 명령은 이유와 되돌리는 법을 함께 적어 주세요.","진단 맡길 때"],
  ["답 바로잡는 말","이 서버는 슬랙웨어 15.0 이라 systemctl·journalctl·apt 가 없어요. /etc/rc.d/rc.[이름]·/var/log·dmesg -T·slackpkg 기준으로 다시 알려 주고, 바꾸는 명령엔 이유와 되돌리는 법을 붙여 주세요.","없는 명령이 섞였을 때"]
 ],
 mistakes:[
  ["쓰는 중인 로그를 rm 으로 지우기","공간이 안 돌아와요. truncate -s 0 으로 비우고, rm 은 회전본(.1·.gz)만, /var/lib/mysql 은 손대지 않아요."],
  ["원격에서 iptables -F·rc.inet1 restart","DROP 정책이면 바로 잠기고, 네트워크 재시작은 잠깐 끊겨요. 콘솔 확보 뒤, 방화벽은 (sleep 300 && /etc/rc.d/rc.firewall) & 를 걸고 해요."],
  ["커널 upgradepkg 뒤 lilo 안 돌리기","다음 부팅이 실패해요. generic 은 geninitrd 뒤 lilo -t → lilo, 옛 커널 항목은 남겨요."],
  ["마운트된·고장 의심 디스크에 fsck","손상이 커져요. 백업 먼저, umount 상태에서만 해요."],
  ["new-config 에서 안 보고 O(덮어쓰기)","설정이 날아갈 수 있어요. D(차이 보기)로 비교한 뒤 K(유지)·O 를 골라요."]
 ]
};
