# CHCNav HCNP (HuaCe Navigation Protocol) 분석 보고서

## 분석 일시
2026-03-18

## 분석 대상

| APK | 버전 | 크기 | 비고 |
|-----|------|------|------|
| Terra-S (테라에스) | 7.3.6.7 (2021-04-21) | 140MB | 한국어 구버전 |
| LandStar (랜드스타) | 8.2.0.1 (2025-11-17) | 196MB | 영문 최신버전 |

## 1. APK 구조

### 보호/난독화
- DEX 코드: **360 Jiagu** 패커로 암호화 (런타임 복호화)
- 네이티브 라이브러리: **난독화 안 됨** — 심볼/함수명 그대로 노출

### 핵심 네이티브 라이브러리

| 라이브러리 | 크기 | 역할 |
|-----------|------|------|
| `libGNSS.so` | 2.9~3.7MB | HCNP 바이너리 프로토콜, 패킷 생성/파싱 |
| `libGNSSJNI.so` | 2.9MB | RTK/PPP 측위 엔진, RTCM 디코딩, CRC24Q |
| `libserial_port.so` | 10KB | 시리얼 포트 JNI 브릿지 |

### 클래스 구조

```
Java Layer (360 Jiagu 암호화)
├── com.huace.gnssserver.ReceiverCmdManager     — 수신기 명령 전송
├── com.huace.gnssserver.device.protocol.DiffConnectManager  — 보정 데이터 흐름 관리
├── com.huace.gnssserver.gnss.PdaDiffOperate    — PDA측 보정 운영
├── com.huace.landstar.device.receiver.rtcm.RtcmDataManager  — RTCM 데이터 관리
└── com.huace.landstar.device.protocol.ntrip.ProtocolNtrip   — NTRIP 프로토콜

Native Layer (libGNSS.so — 심볼 노출)
├── LandStar2011::LSParse::Em_Gnss              — 최상위 GNSS 관리자
├── LandStar2011::LSParse::Em_Format_HuaceNav   — CHCNav 구형 프로토콜 (HuaceNav = 화측도항)
├── LandStar2011::LSParse::Em_Format_HuaceNew   — CHCNav 신형 프로토콜
├── LandStar2011::LSParse::Em_CmdPaker_X10      — X10 바이너리 명령 빌더
├── LandStar2011::LSParse::Em_RepParser_X10     — X10 바이너리 응답 파서
└── LandStar2011::LSParse::Em_MainBd_X10        — X10 메인보드 메시지 프로세서

JNI 인터페이스 (CHC_ReceiverJNI)
├── CHCGetCmdSendDiffDataToOEM    — RTCM을 HCNP 프레임으로 감싸서 OEM 보드에 전송
├── CHCGetCmdInitConnection       — 수신기 초기 연결
├── CHCGetCmdIOConnect            — IO 포트 연결
├── CHCGetCmdIOUpdateDiffType     — 보정 타입 업데이트
├── CHCDataRouting                — 데이터 라우팅 설정
├── CHCGetBTNetData               — BT 네트워크 데이터 (인터넷 공유용, RTCM 별개)
└── CHCEncryptionRequest          — 암호화/활성화 요청
```

## 2. HCNP (X10) 바이너리 프로토콜 프레임 구조

프로토콜 공식 명칭: **HCNP** (HuaCe Navigation Protocol)
내부 코드명: **X10 Protocol**

```
Offset  Size  Field               설명
------  ----  ------------------  -----------------------------------
[0-1]   2B    매직 헤더            항상 0x24 0x24 ("$$")
[2]     1B    방향                0x01=요청(PDA→수신기), 0x02=응답
[3]     1B    시퀀스 번호          0x00~0xFF 순환 증가
[4]     1B    길이 필드            total_frame_size - 7 (0xFA에서 cap)
[5-6]   2B    프로토콜 ID          항상 0x04 0x11
[7-14]  8B    컨텍스트 영역        명령 에코 또는 0x00 패딩
[15]    1B    메시지 카운트         항상 0x01
[16-17] 2B    내부 데이터 길이      Big-Endian
[18-19] 2B    버전/타입             0x00 0x01
[20-21] 2B    상수                 0x00 0x02
[22]    1B    블록 구조 표시        0x00
[23]    1B    카테고리 바이트       명령 그룹 결정
[24-25] 2B    서브 명령             (major, minor)
[26+]   var   파라미터/데이터       명령에 따라 다름
[N-7..N-4] 4B  trailing 바이트     **체크섬 아님** — 버퍼 잔여 데이터
[N-3..N]   4B  터미네이터           0x09 0x24 0x0D 0x0A
```

### 길이 계산 관계
- `byte[4]` = `total_size - 7`
- `inner_len` (byte[16-17]) = byte[22]부터 trailing 4바이트 직전까지
- `total_size` = `inner_len + 26`

## 3. Trailing 4바이트: 체크섬이 아닌 버퍼 쓰레기

### 증거

| 명령 | trailing 바이트 | ASCII | 출처 |
|------|----------------|-------|------|
| #0 (03,06) | `00 03 a9 64` | - | 초기화 안 된 메모리 |
| #1 (03,23) | `00 03 a9 64` | - | 동일 패턴 (다른 명령인데 같음) |
| #6 (03,18) | `72 53 74 61` | "rSta" | "LandStar" 문자열 잔편 |
| #7 (07,12) | `72 53 74 61` | "rSta" | 동일 |
| #11 (03,18) | `64 53 74 61` | "dSta" | "LandStar" 잔편 |
| #16 (04,5a) | `65 72 52 65` | "erRe" | "ReceiverRe..." 잔편 |
| #25 (04,5e) | `6f 70 4d 61` | "opMa" | "StopMa..." 잔편 |
| RTCM #last | `00 00 00 00` | - | 제로 초기화된 버퍼 |

**결론**: C++의 `Em_CmdPaker_X10` 클래스가 `Init_Business_Packet`으로 버퍼를 초기화할 때 trailing 영역을 0으로 초기화하지 않아 이전 메모리 내용이 그대로 남음. **수신기(i70)는 이 바이트를 무시함**.

### CRC는 어디에 사용되나
`libGNSS.so`에 CRC32 (다항식 0xEDB88320)와 CRC24Q 구현이 있지만:
- `Init_Business_Packet_CRC` → 펌웨어 전송 패킷에만 사용
- `Em_Check::CalculateCRC24` → RTCM3 프레임 검증에만 사용
- **일반 명령/쿼리 프레임에는 CRC 없음**

## 4. RTCM 보정 데이터 릴레이

### 데이터 흐름 (PDA CORS 모드)

```
NTRIP 서버 → (인터넷) → 폰/태블릿 → (BT SPP) → i70 수신기 → OEM 보드
                         │
                         ├─ NTRIP 클라이언트 (RTCM3 수신)
                         ├─ CHCGetCmdSendDiffDataToOEM (JNI)
                         ├─ Em_Gnss::Send_DiffDataToGnss
                         ├─ Em_Format_HuaceNav::Send_DiffDataToGnss
                         └─ Em_CmdPaker_X10::Construct_Transfer_Packet
```

### 보정 데이터 경로 2가지
1. **Inner CORS** (`RoverInnerCorsStartState`): 수신기 내장 모뎀으로 NTRIP 직접 연결
2. **PDA CORS** (`RoverPdaCorsStartState`): 폰이 NTRIP 처리, BT로 RTCM 전달 ← **우리 앱 방식**

### RTCM 래퍼 프레임 구조

```
[0-1]   24 24              $$ 매직
[2]     01                 요청 방향
[3]     seq                시퀀스 번호
[4]     len                total - 7
[5-6]   04 11              프로토콜 ID
[7-14]  00 * 8             컨텍스트 (0x00)
[15]    01                 메시지 카운트
[16-17] inner_len          내부 데이터 길이 (BE)
[18-19] 00 01              버전
[20-21] 00 02              상수
[22-23] 00 32              카테고리 (RTCM 릴레이)
[24-25] 15 04              서브커맨드 (DataLink_Differential_Data)
[26-27] block_len          RTCM 프레임 길이 + 4 (BE)
[28-29] 00 00              예약
[30-31] frame_len          RTCM 프레임 길이 (BE)
[32+]   D3 ...             RTCM3 프레임 (헤더 + 데이터 + CRC24Q)
[N-7..N-4] 00 00 00 00     trailing (무시됨)
[N-3..N]   09 24 0D 0A     터미네이터
```

네이티브 함수 체인:
```
CHCGetCmdSendDiffDataToOEM (JNI)
  → Em_Gnss::Send_DiffDataToGnss(vector<STR_CMD>&, uint8_t*, uint32_t)
    → Em_Format_HuaceNav::Send_DiffDataToGnss(vector<STR_CMD>&, uint8_t*, uint32_t)
      → Em_CmdPaker_X10::Construct_Transfer_Packet(vector<STR_CMD>&, uint8_t*, uint16_t)
```

## 5. 초기화 명령 ID 해독

### 카테고리별 분류

| 카테고리 | 서브 명령 | 용도 |
|---------|----------|------|
| `0x0a` | 03,11 / 03,20 | **SET** — 보정 입력 모드, 보정 모듈 |
| `0x0b` | 03,06~03,23 | **QUERY** — 기기정보, 설정 조회 |
| `0x0e` | 04,04~04,52 | **CONFIG** — 포트 설정, IO 라우팅 |
| `0x0f` | 04,04+04,5a | **QUERY** — 포트 설정 조회 (멀티블록) |
| `0x17` | 07,0f~07,23 | **QUERY** — 위성/트래킹 정보 |
| `0x26` | 0b,07 / 0b,09 | **QUERY** — 기준국 정보 |
| `0x2a` | 14,06 / 14,09 | **QUERY** — 그룹 14 |
| `0x2b` | 14,0e | **QUERY** — 그룹 14 |
| `0x2e` | 11,09 | **QUERY** — 그룹 11 |
| `0x32` | 15,04 | **RTCM 릴레이** |

### 핵심 명령 ID 상세

| ID | 네이티브 함수명 | 설명 |
|----|---------------|------|
| 03,06 | `HC_CMD_ID_SYSTEM_FIRMWARE_VERSION` | 펌웨어 버전 조회 |
| 03,0c | `IODiffType` | 보정 프로토콜 타입 조회 |
| 03,11 | `IOEnable` | 보정 입력 모드 활성화 |
| 03,14 | `HC_CMD_ID_SYSTEM_HARDWARE_INFO` | 하드웨어 정보 조회 |
| 03,18 | `HC_CMD_ID_SYSTEM_RECEIVER_MODE` | 수신기 모드 조회 |
| 03,20 | `DiffModule` | 보정 모듈 설정 (RTK/DGPS) |
| 04,04 | (블록 마커) | 서브 파라미터 블록 마커 (04,5a, 04,54와 결합) |
| 04,30 | `IOConnect` | 보정 포트 설정 |
| 04,50 | (데이터 형식) | 데이터 라우팅 형식 |
| 04,51 | (IO 매핑) | IO 라우트 엔트리 |
| 04,52 | `DataRouting` | IO 데이터 라우팅 테이블 (26바이트) |
| 04,54 | (RTCM 브로드캐스트) | RTCM 브로드캐스트 형식 |
| 04,5a | (IO 보정 소스) | IO 보정 소스 활성화 |
| 04,5b | (보정 포트 래퍼) | 04,30을 감싸는 래퍼 |
| 07,11 | `SatInfo` | 위성 추적 정보 |
| 07,19 | `ConstEnable` | 위성 시스템 활성화 |
| 15,04 | `DataLink_Differential_Data` | **RTCM 보정 데이터 릴레이** |

## 6. 수정된 파라미터 값의 의미

### 04,5a = 0x01 (IO 보정 소스 활성화)
- **0x01** = BT 포트에서 보정 데이터 수신 **활성화**
- 이전 값 0x06은 다른 IO 소스를 가리킴 → i70이 BT의 RTCM을 무시

### 04,54 = 0x23 (RTCM 브로드캐스트 형식)
- **0x23** (35) = RTCMV3 다중 메시지 타입 (비트마스크 또는 enum)
- 이전 값 0x05는 다른 보정 형식 → i70이 RTCM3로 인식하지 않음

### 04,30 = 0x09 (보정 포트)
- **0x09** = GNSS_IO_ID_BT (Bluetooth SPP)

### 03,20 = 0x02 (보정 모듈)
- **0x02** = RTK 모드

### 03,11 = 0x01 (보정 입력 모드)
- **0x01** = 보정 입력 활성화

## 7. OEM 보드 텍스트 명령

i70 내부에 NovAtel/Unicore 호환 OEM 보드가 탑재되어 있으며, HCNP 바이너리 프로토콜을 통해 텍스트 명령을 전달:

```
INTERFACEMODE COM2 RTCMV3 NOVATEL    — COM2 입력=RTCMV3, 출력=NOVATEL
interfacemode com2 unicore rtcmv3 on — Unicore 변형
LOG COM2,GPGGA,ONTIME 1              — 1초마다 GGA 출력
unlogall com%d                        — COM 포트 로깅 중지
SAVECONFIG                            — 설정 저장
```

초기화 명령 시퀀스가 이 텍스트 명령과 동일한 효과를 바이너리 프로토콜로 수행.

## 8. 인증/라이선스

- `CHCEncryptionRequest` — 수신기 활성화/등록 요청 존재
- `HC_REGISTER_CODE_STRUCT`, `HC_REGISTER_TIME_STRUCT` — 등록 코드 구조체
- **RTCM 릴레이에는 인증 불필요** — `CHCGetCmdSendDiffDataToOEM`은 raw 데이터를 받아서 감싸기만 함
- i70 라이선스 키 `47493-75704-35971`은 수신기가 응답으로 보내주는 것 (앱이 보내는 것 아님)

## 9. NTRIP 클라이언트

- 내장 User-Agent: `NTRIP GNSSInternetRadio/1.4.5`
- 수신기 자체에 NTRIP 클라이언트 내장 (Inner CORS 모드용)
- PDA CORS 모드에서는 앱이 NTRIP 처리

## 10. 우리 구현 검증 결과

| 항목 | 상태 | 비고 |
|------|------|------|
| RTCM 래퍼 (`_wrapRtcmInChcFrame`) | ✅ 정확 | 서브커맨드 15,04, 길이 계산 일치 |
| trailing 4바이트 `00 00 00 00` | ✅ 안전 | 수신기가 무시하는 영역 |
| 터미네이터 `09 24 0D 0A` | ✅ 정확 | |
| 초기화 명령 29개 | ✅ 캡처 기반 | btsnoop에서 직접 추출 |
| 04,5a = 0x01 (수정됨) | ✅ 테라에스 동일 | BT 보정 소스 활성화 |
| 04,54 = 0x23 (수정됨) | ✅ 테라에스 동일 | RTCMV3 형식 |
| BT SPP UUID 0x1101 | ✅ 표준 | |
| RFCOMM DLCI 2 | ✅ 동일 | |

## 부록: TerraStar vs LandStar 비교

| 항목 | TerraStar 7.3.6.7 | LandStar 8.2.0.1 |
|------|-------------------|-------------------|
| 언어 | 한국어 | 영문 |
| DEX | 1개 (971 strings) | 19개 (대규모) |
| libGNSS.so | 2.9MB (arm64) | 3.7MB (arm64) |
| 프로토콜 | X10 HCNP 동일 | X10 HCNP 동일 |
| 난독화 | 360 Jiagu | 360 Jiagu |
| RTCM 래퍼 | 15,04 서브커맨드 | 15,04 서브커맨드 |
| 핵심 로직 위치 | libGNSS.so (C++) | libGNSS.so (C++) |
