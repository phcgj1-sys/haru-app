window.SUM_DATA=window.SUM_DATA||{};
window.SUM_DATA["github"]={
 slug:"github",
 title:"깃허브 처음부터 배우기",
 one:"깃허브 계정 보안, 웹·GitHub Desktop으로 기록 올리기, Pages 홈페이지, 브랜치·풀 리퀘스트 협업, 클로드 코드에 안전하게 맡기기.",
 must:[
  ["깃은 도구, 깃허브는 장소","Git(깃)은 내 컴퓨터에서 변화를 기록하고, GitHub(깃허브)는 그 기록을 인터넷에 보관·공개해요."],
  ["작게 자주 커밋","한 가지 변경 = 커밋 한 번, 메시지는 '무엇을 왜' 한 줄(예: 전화번호 오타 고침)."],
  ["시작 전 Pull, 끝나면 Push","웹·두 기기·클로드와 번갈아 쓸 땐 이 순서를 지키고, 한 번에 한 곳에서만 고쳐요."],
  ["비밀은 올리지 않기","비밀번호·토큰·API 키·개인정보는 올리면 지워도 기록에 남아요."],
  ["Pages 조건","무료=Public, 맨 위 소문자 index.html, 반영 최대 약 10분."],
  ["허용 질문 판단","git status·diff·add·commit·push, gh pr create는 허용, --force·-f·reset --hard(확인 없이)·rm -rf는 거절, 모르면 \"이 명령 설명해 줘\"."],
  ["삭제는 되돌릴 수 없음","저장소 삭제(Settings 맨 아래 Danger Zone)는 기록까지 사라져요."]
 ],
 stages:[
  {t:"1단계 · 깃허브가 뭐예요",pts:[
   ["Repository(저장소)는 프로젝트 하나를 담는 서랍이에요. Commit(커밋)=사진 찍기, Push(푸시)=금고로 올리기, Pull(풀)=내려받기, Branch(브랜치)=복사본에서 실험, Merge(머지)=원본에 합치기.","l01"],
   ["아이디는 https://github.com/아이디 처럼 주소의 일부라 공개된다고 생각하고 지어요. Settings → Emails → Keep my email addresses private를 켜면 커밋에 noreply 주소가 들어가요.","l02"],
   ["저장소 탭은 Code(파일)·Issues(할 일)·Pull requests(합치기 요청)·Actions(자동 작업)·Settings(설정). 번역은 뜻 파악용으로만, 버튼 이름은 영어 원문으로 기억해요.","l03"],
   ["Settings → Password and authentication에서 2단계 인증(인증 앱·Passkeys, 수단은 2개 이상)을 켜고 Recovery codes(복구 코드)는 내려받아 종이로 보관해요. '지금 당장 로그인' 메일 링크는 누르지 말고 주소창에 github.com을 직접 쳐요.","l04"],
   ["Star=즐겨찾기, Watch=알림. 초록 Code 버튼 → Download ZIP으로 통째로 받되 실행 파일은 믿을 만한 저장소인지 먼저 봐요. LICENSE가 MIT·Apache면 출처 표기하고 거의 자유, GPL은 고쳐 배포 시 같은 조건으로 공개, 파일 없으면 함부로 쓰지 않아요.","l05"]
  ]},
  {t:"2단계 · 웹에서 저장소 다루기",pts:[
   ["+ → New repository → 이름(영문 소문자·숫자·하이픈) → Public/Private → Add a README file 켜기 → Create repository.","l06"],
   ["Add file → Create new file(확장자 꼭), 고치기는 연필 아이콘, 지우기는 … → Delete file. 모두 Commit changes로 끝나요.","l07"],
   ["Add file → Upload files에 파일·폴더를 끌어다 놓아요. 브라우저는 파일당 약 25MiB(메가바이트), 한 번에 약 100개(바뀔 수 있어요). 같은 이름은 덮어쓰고, 빈 폴더는 안 올라가요.","l08"],
   ["README.md는 첫 화면 설명서로 '무엇·왜·어떻게'만 적어도 돼요. 마크다운: # 제목, ## 소제목, - 목록, **굵게**, [글자](주소), ![설명](images/사진.jpg). Preview 탭으로 확인 후 커밋.","l09"],
   ["commits 숫자나 파일 History로 기록을 봐요(빨강=지워짐, 초록=더해짐). 되돌리기는 옛 내용을 복사해 붙여 넣고 다시 커밋. 이름 바꾸기·옮기기는 연필 → 위 이름 칸 수정(docs/처럼 폴더이름/ 붙이면 이동) → 커밋.","l10"]
  ]},
  {t:"3단계 · 내 컴퓨터와 잇기: GitHub Desktop",pts:[
   ["desktop.github.com에서 설치하고 File → Options → Accounts → Sign in to GitHub.com. 비밀번호는 자동으로 열리는 브라우저에만 넣어요.","l11"],
   ["File → Clone repository…로 저장소를 내 컴퓨터에 복사해요. 폴더 파일을 고치면 Changes에 떠요. 남의 저장소는 Clone해도 푸시는 안 돼요(Fork 사용).","l12"],
   ["Changes에서 파일 체크 → Summary (required) 한 줄 → Commit to main. 되돌리기는 History에서 우클릭 → Revert changes in commit.","l13"],
   ["Fetch origin은 새 소식 확인만, Pull origin은 내려받기, Push origin은 올리기예요. 커밋 안 한 변경이 있으면 Pull 전에 먼저 커밋.","l14"],
   ["있는 폴더는 File → Add local repository…, 새로 시작은 File → New repository…. 처음 올릴 땐 Publish repository이고 Keep this code private 체크를 끄면 공개예요.","l15"],
   [".gitignore에 node_modules/, .env, *.log 처럼 한 줄에 하나 적으면 Changes에 안 떠요. 이미 올라간 파일은 git rm --cached 파일이름으로 추적을 끊어요. 데스크톱은 파일당 약 100MiB까지.","l16"]
  ]},
  {t:"4단계 · 홈페이지로 공개하기: GitHub Pages",pts:[
   ["Pages는 저장소의 HTML을 무료 홈페이지로 보여 줘요. 결제·쇼핑몰·회원 로그인 서비스는 안 되고, 켜면 인터넷에 공개되니 민감 정보는 넣지 않아요.","l17"],
   ["Pages 켜기(도구 참고) 후 진행은 Actions 탭 pages build and deployment(노랑=진행, 초록=완료, 빨간 X=실패).","l18"],
   ["주소는 https://아이디.github.io/저장소이름/. 저장소 이름을 아이디.github.io(소문자)로 지으면 대표 사이트 https://아이디.github.io/가 되고, 계정당 하나예요.","l19"],
   ["클로드가 준 index.html을 Upload files로 같은 이름으로 다시 올리면 덮어써요. index(1).html이면 먼저 이름을 고쳐요.","l20"],
   ["404는 대개 이름·대소문자·폴더 위치 문제(Index.html은 다른 파일). 반영 안 되면 약 10분 → Ctrl+F5 → 시크릿 창. 빨간 X는 메시지를 복사해 클로드에게. 비공개라 안 켜지면 Danger Zone → Change visibility로 공개(개인정보 먼저 확인).","l21"]
  ]},
  {t:"5단계 · 브랜치·이슈·협업",pts:[
   ["main 드롭다운에 이름(예: fix-title) 입력 → Create branch. 여러 파일·되돌리기 어려운 변경·남과 함께면 브랜치, 한 줄 고침은 main에 바로.","l22"],
   ["Pull requests → New pull request → base: main / compare: 내 브랜치 → Create pull request(두 번) → Files changed에서 모르는 파일·비밀키가 없는지 확인(빨간 표시면 멈춤) → Merge pull request → Confirm merge → Delete branch(선택).","l23"],
   ["Issues → New issue로 할 일·버그를 적고 Labels(bug, enhancement)를 붙이고 끝나면 Close. 커밋 메시지에 #번호를 적으면 연결돼요.","l24"],
   ["남의 저장소는 Fork → 내 복사본에서 브랜치로 고침 → 원본에 풀 리퀘스트. 합칠지는 원본 주인이 정해요. CONTRIBUTING.md를 먼저 읽고 한 번에 한 가지만. 복사본이 behind면 Sync fork → Update branch.","l25"],
   ["Settings → Collaborators → Add people로 초대하고 수락하면 완료. Write는 커밋·푸시 가능, 설정·삭제는 Admin만.","l26"]
  ]},
  {t:"6단계 · 클로드와 함께 쓰기",pts:[
   ["클로드 코드는 내 컴퓨터의 Git으로 커밋·푸시하고, 깃허브 서버와는 gh로 말해요. gh auth login 브라우저 승인은 사람이 하고, 결과 확인도 사람 책임이에요.","l27"],
   ["\"바뀐 것 확인하고 커밋해 줘\", \"깃허브에 올려 줘\", \"방금 커밋 되돌려 줘\"(되돌리는 새 커밋이 생김). 클로드가 만든 풀 리퀘스트는 Files changed를 보고 내가 직접 병합해요.","l28"],
   ["충돌은 같은 줄을 두 곳에서 고칠 때 생겨요. 남길 쪽을 정해 \"충돌 풀어 줘\". 폴더가 꼬이면 이름을 my-first-repo-old로 바꾸고 다시 Clone 후 필요한 파일만 옮겨요.","l29"],
   ["Actions=자동 작업 로봇, Codespaces=브라우저 코딩 환경, Copilot=AI 도우미. 무료: 저장소 무제한, Actions 월 약 2,000분(바뀔 수 있어요). 다음은 docs.github.com/ko.","l30"]
  ]}
 ],
 tools:[
  ["Pages 켜기","Settings → Pages → Source: Deploy from a branch → Branch: main / (root) → Save","저장소를 홈페이지로 공개할 때"],
  ["기본 .gitignore","node_modules/\n.env\n*.log\nThumbs.db\n.DS_Store\n*.zip\n개인정보/","올리면 안 되는 파일 막기"],
  ["gh 설치·로그인","winget install --id GitHub.cli\n(터미널 다시 열기)\ngh auth login → GitHub.com → 브라우저에서 코드 입력·승인\ngh auth status","클로드 코드가 깃허브와 일하게 할 때 (Windows)"],
  ["작업 전 당부","이 저장소 작업 규칙: 1) 커밋 전에 바뀐 파일 목록을 보여 줘 2) 강제 푸시는 하지 마 3) 비밀키·토큰 파일은 절대 커밋하지 말고 .gitignore 에 넣어 줘 4) 커밋 메시지는 한국어로","클로드 코드 세션 시작 때 한 번"],
  ["되돌리기 부탁","[index.html] 을 [어제 오후] 상태로 되돌려 줘. 기록은 지우지 말고 되돌리는 새 커밋으로 해 줘.","잘못 고친 걸 되돌릴 때"]
 ],
 mistakes:[
  ["비밀키 파일을 지우기만 하고 끝냄","발급처에서 폐기·재발급 → 새 키는 .env에 두고 .gitignore에 추가. 기록 삭제는 시도하지 않아요."],
  ["home.html, Index.html, index(1).html로 올림","첫 화면 파일은 맨 위에 소문자 index.html."],
  ["Commit to main만 누르고 올라갔다고 생각함","위쪽 Push origin까지 눌러야 깃허브에 올라가요."],
  ["웹에서 고친 뒤 내 컴퓨터에서 바로 작업","먼저 Fetch origin → Pull origin, 끝나면 Push."]
 ]
};
