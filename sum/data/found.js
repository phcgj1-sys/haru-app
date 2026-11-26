window.SUM_DATA=window.SUM_DATA||{};
window.SUM_DATA["found"]={
 slug:"found",
 title:"AI 기초: 개발 환경과 수학",
 one:"AI 개발 환경(uv·git·GPU·API 키·도커·리눅스·디버깅)과 AI에 쓰는 수학(선형대수·미분·확률·최적화·통계)을 규칙과 공식만 모았어요.",
 must:[
  ["아래층부터 설치","시스템 기반→패키지 관리자→언어 런타임→AI 라이브러리 순서. GPU가 없어도 대부분 수업은 CPU로 돼요."],
  ["프로젝트마다 가상환경","uv로 만들고 pyproject.toml과 lockfile(uv.lock)을 git에 올려 버전을 고정해요."],
  ["키·큰 파일은 git에서 빼기","API 키는 환경 변수나 .env에 두고, .env(비밀 키)와 .venv/·*.pt 같은 큰 파일은 .gitignore에 적어요."],
  ["shape부터 확인","행렬곱 (m x n) @ (n x p) = (m x p), 안쪽 n이 같아야 해요. 오류가 나면 두 shape을 먼저 찍어요."],
  ["학습률이 가장 중요","너무 크면 튀어서 발산(NaN), 너무 작으면 기어요. 10배씩 바꿔 손실 곡선을 봐요."],
  ["차이는 통계로 확인","p값과 효과 크기(Cohen's d)를 함께 보고, 테스트 셋은 마지막에 한 번만 써요."]
 ],
 stages:[
  {t:"1단계 · 개발 환경 기본",pts:[
   ["환경은 4층(시스템 기반·패키지 관리자·언어 런타임·AI 라이브러리)이고 아래층부터 깔아요. 파이썬은 uv, 타입스크립트는 pnpm. verify.py --route beginner로 내 경로에 필요한 것만 점검하고 실패 줄을 위에서부터 고쳐요.","l01"],
   ["git은 add→commit→push 흐름이에요. 실험은 새 브랜치에서 하고, 코스 저장소에 push할 수 없으면 내 Fork를 clone해 작업해요.","l02"],
   ["GPU는 강의 코스에서 모델을 직접 학습하는 4단계부터 필요해요(이 요약의 4단계와 다름. 내 PC NVIDIA·무료 Colab·클라우드 GPU). fp16은 파라미터 하나에 약 2바이트라 VRAM 바이트/2가 이론상 상한이고, 실제로는 여유를 크게 남겨요.","l03"],
   ["AI API는 주소·키·요청 본문·응답 본문 4가지예요. 401은 키 틀림, 429는 요청 과다(잠시 뒤 재시도), 400은 본문 오류, 5xx는 서버 문제. 키가 노출되면 콘솔에서 바로 폐기하고 새로 만들어요.","l04"],
   ["노트북 셀은 커널 하나를 공유해 실행 순서가 꼬이면 숨은 상태가 생겨요. 탐색은 노트북, 완성은 스크립트로 하고 공유 전 Kernel > Restart & Run All을 해요.","l05"],
   ["uv가 기본, venv·conda는 대안. conda에서는 패키지도 conda로 관리하고, pip가 꼭 필요하면 맨 나중에 해요. 켠 뒤 which python이 .venv 안을 가리키는지 봐요.","l06"],
   ["기반 이미지는 컴파일 필요 devel, 실행만 runtime, CPU 도구 slim 중 가장 작은 걸 골라요. 모델 파일은 -v 볼륨으로 호스트에 두고, GPU는 NVIDIA Container Toolkit과 --gpus all로 써요. 여러 서비스는 Docker Compose로 한 번에 띄워요.","l07"]
  ]},
  {t:"2단계 · 도구와 디버깅",pts:[
   ["VS Code에 Python·Pylance·Jupyter·Remote SSH 등을 깔고 editor.formatOnSave를 켜요.","l08"],
   ["데이터는 load_dataset으로 받고 너무 크면 streaming=True. 저장은 Parquet, 분할(예: 70/15/15)은 seed=42처럼 고정해요. 큰 파일은 .gitignore→Git LFS→DVC 순으로 필요할 때 올려요.","l09"],
   ["로그는 파이프(|)로 거르고 > 파일 2>&1로 출력과 에러를 한 파일에 남겨요. 긴 학습은 tmux 안에서(&는 닫으면 죽고 nohup은 다시 못 붙음), 큰 폴더는 rsync(바뀐 부분만 전송).","l10"],
   ["Permission denied는 대개 권한 문제라 ls -l로 보고 chmod +x나 sudo로 풀어요. rm -rf는 휴지통 없이 지우니 경로를 두 번 확인하고, 디스크는 df -h·du -sh로 먼저 봐요.","l11"],
   ["shape·dtype·device·NaN을 찍고 이상할 때만 breakpoint()로 멈춰요. 데이터 로딩이 병목이면 num_workers를 늘려요. 곡선은 tensorboard --logdir=runs로 보고, train은 내려가는데 val이 오르면 과적합이에요.","l12"],
   ["조용한 함정 3종: b = a는 복사가 아님(a.copy()), def f(x=[]) 대신 None 기본값, 제너레이터는 한 번만 쓰임(에포크마다 새로). 숫자 반복문은 NumPy 벡터화로 옮겨요.","l13"]
  ]},
  {t:"3단계 · 선형대수와 미적분",pts:[
   ["내적은 비슷함을 재요: 양수면 비슷, 0이면 직각, 음수면 반대. 코사인 유사도 = a·b/(|a||b|). 랭크가 열 개수보다 작으면 겹치는 특징이 있어 가중치가 불안정해요.","l14"],
   ["*는 같은 자리끼리 곱, @는 행렬곱이에요. 신경망 한 층은 relu(W @ x + b)이고 편향은 브로드캐스팅으로 더해요. 행렬식이 0이면 역행렬이 없어요.","l15"],
   ["행렬의 열은 기저 벡터가 도착하는 자리예요. 행렬곱은 순서가 바뀌면 결과가 달라요. 고유벡터는 A @ v = λ v로 방향이 안 변하고, 고유값의 합은 대각합·곱은 행렬식이에요.","l16"],
   ["경사 하강은 w = w - lr * dL/dw, 기울기의 반대로 가요. 해석적 미분은 수치 미분 (f(x+h)-f(x-h))/(2h)으로 검산해요.","l17"],
   ["연쇄 법칙은 고리별 미분을 곱해요(sin(x^2) → cos(x^2)*2x). 가중치는 많고 손실은 하나라 신경망은 역방향(역전파)을 써요. PyTorch x.grad는 누적되니 매 단계 비워요.","l18"]
  ]},
  {t:"4단계 · 확률·최적화·정보",pts:[
   ["분류 출력은 PMF, 연속 변수는 PDF이고 PDF 값은 1보다 클 수 있어요. 소프트맥스는 로짓을 합 1인 확률로 바꾸고, 긴 확률 곱은 언더플로를 피하려고 로그를 더해요.","l19"],
   ["베이즈: P(A|B) = P(B|A)·P(A)/P(B). 병이 만 명에 한 명이면 99% 정확한 검사의 양성도 실제 병일 확률은 약 1%예요. 나이브 베이즈는 +1 스무딩으로 0 확률을 막고, MAP는 L2 정규화와 같아요.","l20"],
   ["SGD 미니배치 32~256, 모멘텀(보통 0.9)은 지그재그를 줄여요. Adam은 가중치마다 걸음을 조절해요(lr=1e-3에서 시작). 손실이 커지거나 NaN이면 학습률 1/10, 거의 안 변하면 키우고, 초반 불안정은 웜업, 후반 출렁임은 감쇠 스케줄.","l21"],
   ["정보량은 -log p, 엔트로피는 그 평균이에요. 교차 엔트로피 = 엔트로피 + KL이라 분류 손실을 줄이면 KL이 줄어요. 퍼플렉시티 e^H는 헷갈리는 선택지의 유효 개수예요.","l22"]
  ]},
  {t:"5단계 · 차원과 수치 계산",pts:[
   ["PCA는 평균 빼기→공분산→고유값 분해→정렬→위 k개로 투영. k는 보통 누적 설명 분산 90~95%(또는 팔꿈치 지점)로 정해요. t-SNE·UMAP은 2D 그림용이고 군집 사이 거리는 해석하지 않아요.","l23"],
   ["SVD는 모든 행렬을 A = U·Σ·V^T로 나눠요. 위 k개만 남긴 근사가 랭크 k 중 최선이고, 저장량은 k x (m + n + 1)이에요.","l24"],
   ["브로드캐스트는 shape을 오른쪽부터 맞춰 같거나 1이면 돼요. reshape은 원소 수가 같아야 하고, 전치는 strides(메모리 건너뛰는 간격)만 바꿔 비연속이 돼요. einsum은 입력에만 있는 글자를 합해요.","l25"],
   ["NaN은 학습률 낮추기→입력 nan·inf 검사→분모·log에 1e-8→클리핑(예: max_norm 1.0)→float16이면 손실 스케일링이나 bfloat16 순으로 잡아요. 기울기 검사 상대 오차는 1e-5 미만이면 허용, 1e-3 넘으면 버그일 가능성이 커요.","l26"],
   ["L1은 절댓값 합, L2는 직선 거리, L∞는 가장 큰 차이예요. 텍스트·임베딩은 코사인, 상관된 특성의 이상치는 마할라노비스. L1 규제는 일부 가중치가 정확히 0이 되기 쉬워요.","l27"]
  ]},
  {t:"6단계 · 통계와 심화 수학",pts:[
   ["p값은 H0이 참일 때 이만큼 극단적인 데이터가 나올 확률이지 가설이 참일 확률이 아니에요. 같은 교차 검증 폴드로 짝지은 t-검정을 하고, 검정 20개면 본페로니로 α를 검정 수로 나눠 0.05/20 = 0.0025로 써요. 표본이 아주 크면 사소한 차이도 유의해요.","l28"],
   ["temperature가 낮으면 1등에 확률이 몰리고 높으면 무작위해져요(강의 기준 출발점: 사실 T=0, 코드 0.3~0.7, 대화 0.7~1.0, 창작 1.0~1.5. 서비스마다 달라요). top-p는 누적 확률로 잘라 확신할 때 후보가 적어요. VAE는 z = μ + σ·ε로 기울기를 흘려요.","l29"],
   ["모르겠으면 np.linalg.solve·lstsq부터 써요. Ax=b는 한 번이면 가우스 소거, 같은 A로 여러 번이면 LU, 대칭 양의 정부호면 숄레스키예요. 풀기 전 np.linalg.cond, 푼 뒤 잔차를 봐요.","l30"],
   ["볼록 문제는 지역 최솟값이 곧 전역 최솟값이에요(f''≥0). 신경망 손실은 볼록이 아니고, 뉴턴 방법은 헤세 행렬이 너무 커서 큰 모델에 못 써요.","l31"],
   ["복소수 곱셈은 크기는 곱하고 각도는 더해요. e^(iθ) = cos θ + i·sin θ는 회전이에요. FFT는 O(N log N), 최대 주파수는 fs/2이고(높이려면 fs↑, 가까운 주파수 구분은 N↑, 창은 보통 Hann) 시간의 합성곱은 주파수의 곱이에요.","l32,l33"],
   ["라플라시안 L = D - A의 0인 고윳값 개수가 연결 덩어리 수예요. GNN 메시지 전달을 K번 하면 K칸 이웃까지 정보가 모여요.","l34"],
   ["랜덤 워크 거리는 √n에 비례하고, 마르코프 사슬은 다음 상태가 현재에만 달려 정상 분포로 수렴해요. 메트로폴리스는 초기 구간(burn-in)을 버리고 수락률 ~23%로 보폭을 맞춰요.","l35"]
  ]}
 ],
 tools:[
  ["uv 가상환경","uv venv\nsource .venv/bin/activate   (윈도우: .venv\\Scripts\\activate)\nuv pip install numpy matplotlib jupyter\npython -c \"import numpy; print(numpy.__version__)\"","새 프로젝트 환경 만들 때"],
  ["git 매일 4줄","git status\ngit add 파일이름\ngit commit -m \"무엇을 했는지 한 줄\"\ngit push origin 브랜치이름","작업 저장·백업할 때"],
  ["GPU 확인","nvidia-smi\npython -c \"import torch; print(torch.cuda.is_available())\"\ndevice = torch.device(\"cuda\" if torch.cuda.is_available() else \"cpu\")\nmodel=model.to(device); x=x.to(device)","nvidia-smi 실패면 드라이버, False면 PyTorch 설치 점검. 모델·데이터는 같은 device에"],
  ["로그 남기기·tmux","python train.py > train_full.log 2>&1\ntmux new -s train   (Ctrl+B 후 d: 분리)\ntmux attach -t train","긴 학습을 돌릴 때"],
  ["디스크 점검","df -h\ndu -sh ~/.cache/* | sort -h\nfind . -name \"*.ckpt\" -size +1G","디스크가 가득 찼을 때(지우기 전에 보기)"],
  ["텐서 한 줄 점검","print(f\"{name}: shape={t.shape}, dtype={t.dtype}, device={t.device}, has_nan={t.isnan().any().item()}\")\nif loss.item() > 100 or torch.isnan(loss): breakpoint()","결과가 이상하거나 NaN일 때"],
  ["안전한 소프트맥스","e=np.exp(z-z.max()); p=e/e.sum()\nloss=-np.log(p[y])   (y: 정답 번호)","로짓을 확률·손실로 바꿀 때"],
  ["옵티마이저","opt = torch.optim.Adam(model.parameters(), lr=1e-3)\nopt = torch.optim.SGD(model.parameters(), lr=1e-2, momentum=0.9)","학습 시작점 설정"],
  ["부트스트랩 신뢰구간","rng=np.random.default_rng(0)\nboots=[rng.choice(scores, len(scores)).mean() for _ in range(2000)]\nprint(np.percentile(boots,[2.5,97.5]))","점수의 95% 구간. 두 모델 차이의 구간이 0을 포함하면 진짜 차이라 하기 어려워요"],
  ["PCA 자동 개수","from sklearn.decomposition import PCA\npca=PCA(n_components=0.95); Z=pca.fit_transform(X)","차원을 줄일 때"]
 ],
 mistakes:[
  ["99% 같은 점수를 그대로 믿음","train·test id 겹침과 시간 순서 누수부터 확인해요."],
  ["t-SNE 군집 사이 거리로 판단","묶음만 참고하고, 전처리·압축에는 PCA를 써요."],
  ["p값이 작으니 배포","효과 크기와 배포 비용도 보고, 테스트 셋은 마지막에 한 번만 써요."]
 ]
};
