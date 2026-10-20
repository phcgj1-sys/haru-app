// 하루영어 영화 장면 듣기 (자막 없이 듣기 훈련) — 창작 대본
// lines: [화자, 영어(구어체·축약 포함), 한국어]  · qs: 이해 확인 문제 (정답 index = a)
window.HARU_SCENES = [
{id:"sc01",lv:1,title:"The Late Train",ko:"늦은 기차",setting:"기차역 플랫폼. 두 친구가 기차를 기다린다.",lines:[
["Mia","Where is he? The train's gonna be here any minute.","그 애 어디 있어? 기차 금방 올 텐데."],
["Jake","Relax. He texted me. He's two minutes away.","진정해. 문자 왔어. 2분 거리래."],
["Mia","He said that ten minutes ago.","10분 전에도 그랬잖아."],
["Jake","Okay, fair point.","그래, 맞는 말이야."],
["Mia","If we miss this one, the next one's at nine.","이거 놓치면 다음 건 9시야."],
["Jake","We're not gonna miss it. Look, there he is!","안 놓쳐. 봐, 저기 온다!"],
["Sam","Sorry, sorry! I couldn't find my wallet.","미안, 미안! 지갑을 못 찾았어."],
["Mia","You're lucky the train's late too.","기차도 늦어서 다행인 줄 알아."],
["Sam","See? It all worked out.","봤지? 다 잘 풀렸잖아."],
["Jake","Just get on the train, Sam.","그냥 기차나 타, 샘."]
],qs:[
{q:"친구들은 왜 조바심을 냈나요?",o:["기차표를 잃어버려서","샘이 늦게 와서","날씨가 나빠서","역을 잘못 찾아서"],a:1},
{q:"샘은 왜 늦었나요?",o:["길이 막혀서","늦잠을 자서","지갑을 못 찾아서","버스를 놓쳐서"],a:2},
{q:"이 기차를 놓치면 다음 기차는 몇 시인가요?",o:["7시","8시","9시","10시"],a:2}
]},
{id:"sc02",lv:1,title:"Coffee Spill",ko:"쏟은 커피",setting:"붐비는 카페. 낯선 두 사람이 부딪힌다.",lines:[
["Nora","Oh no! I'm so sorry!","어머! 정말 죄송해요!"],
["Ben","It's okay, it's okay. It's just a shirt.","괜찮아요, 괜찮아요. 그냥 셔츠인걸요."],
["Nora","It's not okay, it's all over you. Let me buy you another coffee.","안 괜찮아요, 다 묻었잖아요. 커피 한 잔 다시 사 드릴게요."],
["Ben","You really don't have to.","정말 안 그러셔도 돼요."],
["Nora","I insist. What were you having?","꼭 그러고 싶어요. 뭐 드시고 계셨어요?"],
["Ben","Um, just a black coffee.","음, 그냥 블랙커피요."],
["Nora","One black coffee, coming up. I'm Nora, by the way.","블랙커피 하나, 바로 갈게요. 참, 저는 노라예요."],
["Ben","Ben. Nice to meet you, even like this.","벤이에요. 이렇게라도 만나서 반가워요."],
["Nora","Hey, at least you'll remember me.","뭐, 적어도 절 기억은 하시겠네요."],
["Ben","That's for sure.","그건 확실하죠."]
],qs:[
{q:"무슨 일이 있었나요?",o:["노라가 벤의 커피를 마셨다","노라가 벤에게 커피를 쏟았다","벤이 커피를 떨어뜨렸다","둘이 같은 자리에 앉았다"],a:1},
{q:"벤은 무엇을 마시고 있었나요?",o:["라테","차","블랙커피","주스"],a:2},
{q:"노라는 무엇을 하겠다고 했나요?",o:["셔츠를 빨아 주겠다","커피를 다시 사 주겠다","사과 편지를 쓰겠다","돈을 주겠다"],a:1}
]},
{id:"sc03",lv:2,title:"The Job Offer",ko:"일자리 제안",setting:"저녁, 아파트. 전화벨이 울린다.",lines:[
["Lena","Hello?","여보세요?"],
["Mr. Park","Hi, Lena, it's Mr. Park from Greenlight. Is this a good time?","안녕하세요 레나 씨, 그린라이트의 박입니다. 지금 통화 괜찮으세요?"],
["Lena","Yes, of course!","네, 물론이죠!"],
["Mr. Park","Good news. We'd like to offer you the position.","좋은 소식이에요. 그 자리를 제안드리고 싶습니다."],
["Lena","Wait, really? Oh my gosh.","잠깐, 정말요? 세상에."],
["Mr. Park","Really. We were all impressed. Can you start on the first?","정말이요. 다들 인상 깊게 봤어요. 1일에 시작하실 수 있나요?"],
["Lena","The first... that's in two weeks. I'll have to give notice at my current job.","1일이면... 2주 뒤네요. 지금 회사에 그만둔다고 말해야 해요."],
["Mr. Park","Totally understandable. Take a day or two and let me know.","충분히 이해합니다. 하루 이틀 생각해 보고 알려 주세요."],
["Lena","I don't need a day. Yes. I'm in.","하루도 필요 없어요. 네. 할게요."],
["Mr. Park","Wonderful. Welcome to the team, Lena.","잘됐네요. 팀에 온 걸 환영해요, 레나."]
],qs:[
{q:"박 씨는 왜 전화했나요?",o:["면접 일정을 잡으려고","일자리를 제안하려고","서류를 요청하려고","약속을 취소하려고"],a:1},
{q:"레나는 언제 시작할 수 있는지 물었나요?",o:["다음 주 월요일","이번 달 말","1일","내일"],a:2},
{q:"레나는 어떻게 대답했나요?",o:["며칠 생각해 보겠다고 했다","바로 수락했다","거절했다","월급을 물어봤다"],a:1}
]},
{id:"sc04",lv:2,title:"Movie Night",ko:"영화 보는 밤",setting:"거실 소파. 커플이 리모컨을 두고 다툰다.",lines:[
["Chris","Okay, what are we watching?","자, 뭐 볼까?"],
["Dana","Not another action movie. Please.","또 액션 영화는 안 돼. 제발."],
["Chris","What? Last week was your pick!","뭐? 지난주는 네가 골랐잖아!"],
["Dana","And it was a great pick. Everybody cried.","그리고 잘 골랐지. 다들 울었잖아."],
["Chris","I didn't cry.","난 안 울었어."],
["Dana","You totally cried.","완전 울었거든."],
["Chris","Fine. Something funny, then. I'm not in the mood to think.","알았어. 그럼 웃긴 거. 머리 쓸 기분 아니야."],
["Dana","Deal. But you're making the popcorn.","좋아. 대신 팝콘은 네가 만들어."],
["Chris","Why am I always making the popcorn?","왜 항상 내가 팝콘을 만들어?"],
["Dana","'Cause you're good at it. Go.","네가 잘하니까. 어서."]
],qs:[
{q:"다나는 무엇을 보고 싶지 않다고 했나요?",o:["로맨스 영화","공포 영화","액션 영화","다큐멘터리"],a:2},
{q:"지난주에는 누가 영화를 골랐나요?",o:["크리스","다나","둘 다","친구"],a:1},
{q:"결국 어떤 영화를 보기로 했나요?",o:["슬픈 영화","웃긴 영화","액션 영화","아직 못 정함"],a:1}
]},
{id:"sc05",lv:2,title:"The Lost Dog",ko:"잃어버린 개",setting:"저녁 무렵 주택가 골목.",lines:[
["Owen","Excuse me! Have you seen a small brown dog? About this big?","저기요! 작은 갈색 개 못 보셨어요? 이만한?"],
["Ruth","A brown dog... with a red collar?","갈색 개... 빨간 목줄 한?"],
["Owen","Yes! That's Biscuit. He got out this morning.","네! 비스킷이에요. 오늘 아침에 나가 버렸어요."],
["Ruth","I saw him by the playground maybe an hour ago.","한 시간쯤 전에 놀이터 옆에서 봤어요."],
["Owen","The playground? He hates the playground.","놀이터요? 걔 놀이터 싫어하는데."],
["Ruth","Well, he looked pretty happy to me. Some kids were feeding him.","제가 보기엔 꽤 행복해 보이던데요. 아이들이 먹을 걸 주고 있었어요."],
["Owen","Of course they were. That dog would follow anyone with a sandwich.","당연히 그랬겠죠. 그 개는 샌드위치 든 사람이면 누구든 따라가요."],
["Ruth","Come on, I'll walk you over there.","가요, 제가 거기까지 같이 가 드릴게요."],
["Owen","You don't have to do that.","안 그러셔도 되는데."],
["Ruth","I wanna see the happy ending.","해피엔딩을 보고 싶어서요."]
],qs:[
{q:"오웬은 무엇을 찾고 있나요?",o:["고양이","지갑","개","아이"],a:2},
{q:"루스는 개를 어디서 봤나요?",o:["공원 입구","놀이터 옆","가게 앞","버스 정류장"],a:1},
{q:"아이들은 개에게 무엇을 하고 있었나요?",o:["쫓아내고 있었다","먹을 것을 주고 있었다","씻기고 있었다","사진을 찍고 있었다"],a:1}
]},
{id:"sc06",lv:2,title:"Last-Minute Trip",ko:"갑작스러운 여행",setting:"주방. 두 룸메이트가 노트북을 보고 있다.",lines:[
["Tess","Okay, hear me out. Flights to Jeju are super cheap this weekend.","자, 내 말 좀 들어 봐. 이번 주말 제주 항공권이 엄청 싸."],
["Ravi","This weekend? As in, two days from now?","이번 주말? 그러니까 이틀 뒤?"],
["Tess","Yep. We could leave Friday night and come back Sunday.","응. 금요일 밤에 떠나서 일요일에 돌아오는 거야."],
["Ravi","I've got that thing on Saturday, though.","근데 나 토요일에 그 일 있잖아."],
["Tess","What thing?","무슨 일?"],
["Ravi","The... okay, I don't have a thing.","그... 알았어, 아무 일도 없어."],
["Tess","So that's a yes?","그럼 간다는 거지?"],
["Ravi","How cheap are we talking?","얼마나 싼데?"],
["Tess","Like, ninety bucks round trip.","왕복 90달러 정도."],
["Ravi","Okay, that's a yes. Book it before I change my mind.","좋아, 간다. 내 마음 바뀌기 전에 예약해."]
],qs:[
{q:"테스는 어디로 가자고 했나요?",o:["부산","제주","도쿄","방콕"],a:1},
{q:"라비는 처음에 왜 망설였나요?",o:["돈이 없어서","토요일에 일이 있다고 해서","비행기를 싫어해서","날씨가 걱정돼서"],a:1},
{q:"왕복 항공권은 얼마였나요?",o:["약 50달러","약 90달러","약 190달러","약 900달러"],a:1}
]},
{id:"sc07",lv:3,title:"The Interview Room",ko:"면접실",setting:"조용한 회의실. 긴장된 면접.",lines:[
["Ms. Cole","So, your resume says you left your last job after only six months.","이력서를 보니 지난 직장을 6개월 만에 그만두셨네요."],
["Dan","That's right.","맞습니다."],
["Ms. Cole","Can you tell me why?","이유를 말씀해 주실 수 있나요?"],
["Dan","Honestly? The company was going in a direction I didn't believe in.","솔직히요? 회사가 제가 믿지 않는 방향으로 가고 있었어요."],
["Ms. Cole","That's a diplomatic answer.","외교적인 답변이네요."],
["Dan","It's the true one. I'd rather leave than do work I'm not proud of.","사실이기도 합니다. 자랑스럽지 않은 일을 하느니 떠나는 게 낫죠."],
["Ms. Cole","And what makes you think this place is different?","그럼 여기는 다를 거라고 생각하는 이유는요?"],
["Dan","I've used your product for three years. I know what it does for people.","귀사 제품을 3년 동안 썼습니다. 이게 사람들에게 뭘 해 주는지 압니다."],
["Ms. Cole","Hm. You know, most people just say they're a team player.","흠. 보통은 그냥 팀워크가 좋다고 말하거든요."],
["Dan","I'm that too. But you asked.","그것도 맞아요. 하지만 물어보셨으니까요."],
["Ms. Cole","I did. Let's keep going.","그랬죠. 계속해 봅시다."]
],qs:[
{q:"댄은 지난 직장에서 얼마나 일했나요?",o:["3개월","6개월","1년","3년"],a:1},
{q:"댄이 그만둔 이유는 무엇인가요?",o:["월급이 적어서","회사 방향이 마음에 안 들어서","이사를 가서","해고당해서"],a:1},
{q:"댄은 이 회사 제품을 얼마나 사용했나요?",o:["써 본 적 없다","6개월","3년","10년"],a:2}
]},
{id:"sc08",lv:3,title:"Rainy Day Café",ko:"비 오는 날 카페",setting:"창가 자리. 오랜만에 만난 두 친구.",lines:[
["Jun","I can't believe it's been three years.","3년이나 됐다니 믿기지가 않아."],
["Ella","Three and a half, actually. But who's counting?","사실 3년 반. 뭐, 누가 세고 있겠어?"],
["Jun","You look exactly the same.","너 하나도 안 변했다."],
["Ella","Liar. But thank you. How's the new place?","거짓말. 그래도 고마워. 새집은 어때?"],
["Jun","Small. Loud. I kinda love it.","좁고. 시끄럽고. 근데 좀 마음에 들어."],
["Ella","That sounds like you.","너답네."],
["Jun","What about you? Still at the hospital?","너는? 아직 병원이야?"],
["Ella","Still there. Night shifts, mostly. I'm basically a vampire now.","아직. 주로 야간 근무야. 이제 거의 뱀파이어야."],
["Jun","Well, you picked a good day to come out. No sun.","오늘 나오길 잘했네. 해가 없잖아."],
["Ella","See? I planned it.","봤지? 내가 계획한 거야."]
],qs:[
{q:"두 사람은 얼마 만에 만났나요?",o:["3개월","1년","3년 반","10년"],a:2},
{q:"준의 새집은 어떤가요?",o:["크고 조용하다","작고 시끄럽다","오래되고 춥다","비싸고 멀다"],a:1},
{q:"엘라는 주로 언제 일하나요?",o:["아침","낮","밤","주말"],a:2}
]},
{id:"sc09",lv:3,title:"The Big Game",ko:"큰 경기",setting:"시끄러운 스포츠 바. 경기 마지막 1분.",lines:[
["Leo","One minute left. One minute! Come on!","1분 남았어. 1분! 가자!"],
["Max","Dude, sit down. You're blocking the screen.","야, 앉아. 화면 가리잖아."],
["Leo","I can't sit. I physically cannot sit right now.","못 앉아. 지금은 몸이 앉질 못해."],
["Max","If they score here, I'm buying everyone a round.","여기서 득점하면 내가 다 한 잔씩 쏜다."],
["Leo","Everyone? That's like forty people.","전부? 40명은 되겠는데."],
["Max","I'm feeling generous. Also, they're not gonna score.","오늘 마음이 넉넉해. 그리고 어차피 득점 못 해."],
["Leo","Don't say that! Don't jinx it!","그런 말 하지 마! 재수 없게!"],
["Max","Here it comes... here it comes...","간다... 간다..."],
["Leo","GOAL! YES! YES!","골! 됐어! 됐어!"],
["Max","Oh no. Oh no, I said everyone.","아 이런. 아 이런, 내가 전부라고 했지."],
["Leo","You did say everyone.","그래, 전부라고 했어."]
],qs:[
{q:"장면이 시작될 때 경기는 얼마나 남았나요?",o:["10분","5분","1분","끝났다"],a:2},
{q:"맥스는 득점하면 무엇을 하겠다고 했나요?",o:["집에 가겠다","모두에게 한 잔씩 사겠다","소리를 지르겠다","내기 돈을 받겠다"],a:1},
{q:"결과는 어떻게 됐나요?",o:["득점하지 못했다","득점했다","경기가 취소됐다","알 수 없다"],a:1}
]},
{id:"sc10",lv:3,title:"Moving Day",ko:"이사하는 날",setting:"텅 빈 방. 상자들 사이의 남매.",lines:[
["Amy","That's the last box. I think.","그게 마지막 상자야. 아마."],
["Tom","You said that three boxes ago.","세 상자 전에도 그랬잖아."],
["Amy","This time I mean it. Look, the closet's empty.","이번엔 진짜야. 봐, 옷장 비었어."],
["Tom","What about under the bed?","침대 밑은?"],
["Amy","...Don't look under the bed.","...침대 밑은 보지 마."],
["Tom","Amy.","에이미."],
["Amy","Okay, there might be a few things under the bed.","알았어, 침대 밑에 뭐가 좀 있을 수도 있어."],
["Tom","I'm gonna need more coffee for this.","이러려면 커피가 더 필요하겠다."],
["Amy","Hey. Thanks for helping. Seriously.","야. 도와줘서 고마워. 진심으로."],
["Tom","That's what brothers are for. Now grab the other end.","이럴 때 쓰라고 오빠가 있는 거지. 자, 저쪽 끝 잡아."]
],qs:[
{q:"두 사람은 무엇을 하고 있나요?",o:["청소","이사 짐 싸기","파티 준비","가구 조립"],a:1},
{q:"에이미는 어디를 보지 말라고 했나요?",o:["옷장","부엌","침대 밑","상자 안"],a:2},
{q:"톰은 에이미와 어떤 관계인가요?",o:["친구","남편","오빠","동료"],a:2}
]}
];

// 듣기 훈련: 영화·대화에서 자주 들리는 축약음·연음
window.HARU_REDUCTIONS = [
["gonna","going to","~할 거야","I'm gonna call you later.","나중에 전화할게."],
["wanna","want to","~하고 싶어","Do you wanna grab lunch?","점심 먹을래?"],
["gotta","have got to / have to","~해야 해","I gotta go.","가야 해."],
["kinda","kind of","약간, 좀","I'm kinda tired.","좀 피곤해."],
["sorta","sort of","약간, 뭐랄까","It's sorta complicated.","좀 복잡해."],
["lemme","let me","내가 ~할게","Lemme see.","어디 봐 봐."],
["gimme","give me","나한테 줘","Gimme a second.","잠깐만."],
["dunno","don't know","몰라","I dunno, maybe.","몰라, 아마도."],
["ya","you","너","See ya!","또 봐!"],
["'cause","because","왜냐하면","I left 'cause I was tired.","피곤해서 나왔어."],
["c'mon","come on","자, 어서 / 에이","C'mon, we're late!","어서, 늦었어!"],
["y'know","you know","있잖아","It's, y'know, complicated.","그게, 있잖아, 복잡해."],
["whatcha","what are you","너 뭐 ~해?","Whatcha doing?","뭐 해?"],
["didja","did you","너 ~했어?","Didja see that?","저거 봤어?"],
["outta","out of","~ 밖으로, ~이 떨어진","Let's get outta here.","여기서 나가자."],
["lotta","lot of","많은","There's a lotta people.","사람이 많네."],
["hafta","have to","~해야 해","I hafta work tomorrow.","내일 일해야 해."],
["ain't","am not / is not / are not","~아니야 (매우 구어적)","That ain't right.","그건 아니지."],
["I'd've","I would have","~했을 텐데","I'd've called you.","전화했을 텐데."],
["should've","should have","~했어야 했는데","I should've known.","알았어야 했는데."],
["could've","could have","~할 수 있었는데","You could've told me.","나한테 말해 줄 수 있었잖아."],
["would've","would have","~했을 거야","I would've helped.","내가 도왔을 거야."],
["what's up","what is up","무슨 일이야? / 안녕","Hey, what's up?","야, 무슨 일이야?"],
["How's it going?","How is it going?","잘 지내?","How's it going, man?","잘 지내, 친구?"],
["Whaddya","What do you","너는 ~해?","Whaddya think?","어떻게 생각해?"],
["I'mma","I am going to","나 ~할 거야 (매우 구어적)","I'mma head out.","나 갈게."],
["innit","isn't it (영국)","그렇지?","Nice day, innit?","날씨 좋네, 그렇지?"],
["dunno what","don't know what","뭔지 몰라","I dunno what to say.","뭐라고 해야 할지 모르겠어."],
["kinda like","kind of like","좀 ~ 같은","It's kinda like a game.","좀 게임 같아."],
["gotcha","got you","알았어 / 잡았다","Gotcha. See you at six.","알았어. 6시에 봐."]
];
