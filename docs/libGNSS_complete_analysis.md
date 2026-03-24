# libGNSS.so 완전 분석 보고서

## 분석 일시
2026-03-18

## 분석 대상

| 항목 | TerraStar 7.3.6.7 | LandStar 8.2.0.1 |
|------|-------------------|-------------------|
| libGNSS.so | 1.53MB (ARM 32-bit) | 3.7MB (ARM64) |
| libGNSSJNI.so | - | 2.9MB (ARM64, RTK 커널) |
| 심볼 수 | 7,244개 | 8,971개 |
| 문자열 수 | 18,321개 | 15,108개 |
| C++ 클래스 | 95개 | 114개 |
| JNI 함수 | 1,780개 | 2,480개 |
| 난독화 | 없음 | 없음 |

### 분석 결과 파일
- `libgnss_analysis/COMPLETE_ANALYSIS.txt` — TerraStar 전체 분석 (13,010줄)
- `libgnss_analysis/symbols.json` — 심볼 7,244개 (디맹글링 포함)
- `libgnss_analysis/strings.json` — 문자열 18,321개
- `libgnss_analysis/jni_functions.txt` — JNI 함수 목록
- `libgnss_analysis/dynsyms_libGNSS.txt` — LandStar 심볼 덤프
- `libgnss_analysis/strings_libGNSS.txt` — LandStar 문자열 덤프

---

## 1. 아키텍처 개요

```
┌─────────────────────────────────────────────┐
│  Java Layer (360 Jiagu 암호화)               │
│  com.huace.gnssserver.ReceiverCmdManager     │
│  com.huace.landstar.device.receiver.*        │
├─────────────────────────────────────────────┤
│  JNI Bridge                                  │
│  com.chc.gnss.sdk.CHC_ReceiverJNI           │
│  (1,780~2,480 네이티브 함수)                  │
├─────────────────────────────────────────────┤
│  libGNSS.so — 프로토콜 핸들링                 │
│  ├── Em_Gnss (마스터 오케스트레이터)           │
│  ├── Em_Format_HuaceNav (구형 프로토콜)       │
│  ├── Em_Format_HuaceNew (신형 X10)           │
│  ├── Em_CmdPaker_X10 (명령 빌더)             │
│  ├── Em_RepParser_X10 (응답 파서)            │
│  ├── Em_TrsMtPrlRTCM (RTCM 디코더)          │
│  └── Em_Check (CRC/체크섬)                   │
├─────────────────────────────────────────────┤
│  libGNSSJNI.so — RTK 커널 (LandStar만)       │
│  ├── ctclib_* (RTK 처리 엔진)                │
│  ├── GNSS/INS 타이트 커플링                   │
│  ├── RTCM 2/3 코덱                          │
│  └── VRS 무결성 모니터링                      │
└─────────────────────────────────────────────┘
```

---

## 2. C++ 클래스 계층 구조

모든 클래스는 `LandStar2011::LSParse::` 네임스페이스 하위.

### 2.1 메인 인터페이스

| 클래스 | 메서드 수 | 역할 |
|--------|----------|------|
| **Em_Gnss** | 687 | 최상위 GNSS 관리자. 모든 수신기 통신 총괄 |

### 2.2 프로토콜 포맷 핸들러

| 클래스 | 메서드 수 | 역할 |
|--------|----------|------|
| Em_Format_HuaceNav | 230 | HuaCe(화측) 독점 프로토콜 (구형 수신기) |
| Em_Format_HuaceNew | 8 | 신형 X10 바이너리 프로토콜 |
| Em_Format_Common | 26 | 범용 OEM 보드 포맷 |
| Em_Format_Common_PDA | 27 | PDA용 범용 포맷 |
| Em_Format_RTKlib | 3 | RTKlib 데이터 포맷 |

### 2.3 명령 빌더 (Em_CmdPaker_*)

22개 OEM 보드별 명령 빌더:

| 클래스 | 메서드 수 | 대상 보드 |
|--------|----------|----------|
| **Em_CmdPaker_X10** | 26~28 | **CHCNav X10 (i70, i80, i90)** |
| Em_CmdPaker_B380 / _PDA | 39/38 | NovAtel B380 |
| Em_CmdPaker_BD / _PDA | 46/46 | Trimble BD |
| Em_CmdPaker_NovAt / _PDA | 39/37 | NovAtel OEM |
| Em_CmdPaker_Unicore / _PDA | 36/14 | Unicore |
| Em_CmdPaker_UB4B0 | 36 | NovAtel UB4B0 |
| Em_CmdPaker_Hemis / P307 / _PDA | 17/17/17 | Hemisphere |
| Em_CmdPaker_UBLox_6T / 8T / F9P_PDA | 15/27/23 | u-blox |
| Em_CmdPaker_CHC_M620_PDA | 23 | CHC M620 |
| Em_CmdPaker_Taidou_PDA | 22 | Taidou |
| Em_CmdPaker_MengXin_PDA | 15 | MengXin |
| Em_CmdPaker_Common / _PDA | 14/14 | 범용 |

### 2.4 응답 파서 (Em_RepParser_*)

17개 응답 파서:

| 클래스 | 메서드 수 | 대상 |
|--------|----------|------|
| **Em_RepParser_X10** | 84~115 | **CHCNav X10 (핵심)** |
| Em_RepParser_BD / _PDA | 25/24 | Trimble BD |
| Em_RepParser_UB4B0 | 28 | NovAtel UB4B0 |
| Em_RepParser_Unicore | 27 | Unicore |
| Em_ReptParser_NovAt / _PDA | 25/23 | NovAtel |
| Em_ReptParser_B380 / _PDA | 25/23 | NovAtel B380 |
| Em_RepParser_Hemis / P307 / _PDA | 11/10/26 | Hemisphere |
| Em_RepParser_UBLox_6T / 8T / F9P_PDA | 5/14/16 | u-blox |
| Em_RepParser_CHC_M620_PDA | 21 | CHC M620 |
| Em_RepParser_MengXin_PDA | 13 | MengXin |
| Em_RepParser_Taidou_PDA | 10 | Taidou |

### 2.5 메인보드 핸들러 (Em_MainBd_*)

14개 메인보드 패킷 프로세서.

### 2.6 데이터/유틸리티 클래스

| 클래스 | 메서드 수 | 역할 |
|--------|----------|------|
| Em_Data_Buffer | 18 | CRC32, 데이터 관리 |
| Em_Cycle_Data_Buffer | 14 | 링 버퍼, CRC24 |
| Em_RTKLIB_Data_Buffer | 14 | RTKlib 데이터 버퍼 |
| Em_Packet_Buffer | 5 | 패킷 버퍼 |
| Em_Check | 5 | CRC24, CRC32, 체크섬 |
| Em_Base64 | 2 | Base64 인코딩 |
| Em_Logger | 10 | 로깅 |
| Em_TrsMtPrlRTCM | 27 | RTCM 디코더 |
| Em_TrsMtPrlCmr | 1 | CMR 프로토콜 |
| Em_HcFmt_PPK | 6 | PPK 형식 |
| Em_HcFmt_Radio | 16 | 무선 형식 |
| Em_HcFmt_WrlesGprs | 11 | GPRS 무선 |
| FeatureFileReader | 83 | 수신기 기능/성능 파일 |
| CHC_DataCaltuate | 9 | 좌표 계산, 틸트 보정 |
| RegValidator | 1 | 라이선스 만료일 확인 |
| ChcPnParser | 3 | PN 파싱 (parsePn13, parsePn18, parsePnA118) |

---

## 3. Em_CmdPaker_X10 상세 (X10 명령 빌더)

i70, i80, i90 등 CHCNav 현대 수신기용 명령 빌더.

### 3.1 전체 메서드 목록

| 메서드 | 크기 | 역할 |
|--------|------|------|
| `Construct_Transfer_Packet` | - | 전송 레이어 패킷 조립 |
| `Get_Block_List_Length` | - | 블록 리스트 전체 길이 계산 |
| `Get_Cmd_Block` | 7,324B | 단일 블록 명령 생성 |
| `Get_Cmd_BaseWarning_Frq` | - | 기지국 경고 주파수 |
| `Get_Cmd_Base_Power_Frq` | - | 기지국 파워 주파수 |
| `Get_Cmd_ElevMask` | - | 앙각 마스크 |
| `Get_Cmd_EphemSat` | - | 위성 궤도력 |
| `Get_Cmd_Ephemeris` | - | 궤도력 데이터 |
| `Get_Cmd_Init` | - | **수신기 초기화** |
| `Get_Cmd_MaskSat` | - | 위성 마스킹 |
| `Get_Cmd_Nmea` | - | NMEA 출력 제어 |
| `Get_Cmd_Obs` | - | 관측 데이터 |
| `Get_Cmd_Packet` | - | BlockInfo 리스트로 전체 패킷 생성 |
| `Get_Cmd_PdopFrq` | - | PDOP 주파수 |
| `Get_Cmd_PosFrq` | - | 위치 주파수 |
| `Get_Cmd_Reset` | - | 수신기 리셋 |
| `Get_Cmd_SatInfo` | - | 위성 정보 |
| `Get_Cmd_StarBs` | - | 기지국 시작 |
| `Get_Cmd_StarRv` | - | 로버 시작 |
| `Get_Cmd_VCV_Frq` | - | VCV 행렬 주파수 |
| `Get_ElevMaskInfo_Command` | - | 앙각 마스크 조회 |
| `Get_UnlogData_Command` | - | 데이터 로깅 중지 |
| `Init_Business_Packet` | - | 비즈니스 레이어 패킷 초기화 |
| `Init_Business_Packet_CRC` | - | **비즈니스 패킷 CRC 초기화 (펌웨어 전송용)** |
| `Packet_Transfer_Data` | - | 전송 데이터 패킹 |
| `Segment_Business_Packet` | - | 비즈니스 패킷 블록 분할 |

### 3.2 패킷 빌드 흐름

```
Get_Cmd_Packet(BlockInfo[] list)
  ├── Get_Block_List_Length(list) → 전체 블록 길이 계산
  ├── Init_Business_Packet(buffer, totalLen) → 버퍼 초기화
  ├── for each block:
  │     └── Get_Cmd_Block(block) → 개별 블록 생성
  ├── Segment_Business_Packet(buffer) → 블록 분할
  └── Construct_Transfer_Packet(cmds, data, len) → 최종 프레임 조립
        └── Packet_Transfer_Data(data, len) → 전송 데이터 패킹
```

### 3.3 X10 프로토콜 레이어 구조

```
┌─ Transfer Layer ─────────────────────────┐
│ $$ [dir] [seq] [len] 04 11 ...           │
│ Construct_Transfer_Packet                 │
│ Packet_Transfer_Data                      │
├─ Business Layer ─────────────────────────┤
│ [msgCount] [innerLen] [version] [const]  │
│ Init_Business_Packet                      │
│ Segment_Business_Packet                   │
├─ Block Layer ────────────────────────────┤
│ [category] [subCmd] [params...]          │
│ Get_Cmd_Block                             │
│ Get_Block_List_Length                      │
├─ CRC Layer (펌웨어 전송만) ──────────────┤
│ Init_Business_Packet_CRC                  │
└──────────────────────────────────────────┘
```

---

## 4. Em_RepParser_X10 상세 (X10 응답 파서)

### 4.1 명령 처리기 (Prc_Cmd_HC_*)

| 처리기 | 크기 | 처리 대상 |
|--------|------|----------|
| `Prc_Cmd_HC_GNSS` | 7,796B | GNSS 명령 (핵심) |
| `Prc_Cmd_HC_System` | - | 시스템 명령 |
| `Prc_Cmd_HC_Radio` | - | 무선 명령 |
| `Prc_Cmd_HC_COM` | - | 시리얼 포트 |
| `Prc_Cmd_HC_DataLink` | - | 데이터 링크 |
| `Prc_Cmd_HC_File_Record` | - | 파일 기록 |
| `Prc_Cmd_HC_Net` | - | 네트워크 |
| `Prc_Cmd_HC_3G` | - | 3G 모뎀 |
| `Prc_Cmd_HC_WIFI` | - | WiFi |
| `Prc_Cmd_HC_SYSTEMSTATUS` | - | 시스템 상태 |
| `Prc_Cmd_HC_CAMERA` | - | 카메라 (LandStar만) |
| `Prc_Cmd_HC_SLAM` | - | SLAM (LandStar만) |

### 4.2 시스템 정보 파싱

```
ParseSystemDeviceCode         — 기기 코드
ParseSystemFirmwareInfo        — 펌웨어 정보
ParseSystemFirmwareVersion     — 펌웨어 버전
ParseSystemHardwareInfo        — 하드웨어 정보
ParseSystemHardWareInfoEX      — 하드웨어 정보 확장
ParseSystemPartInfo            — 부품 정보
ParseSystemPowerStatus         — 전원 상태
ParseSystemGetReceiverMode     — 수신기 모드
ParseSystemRegisterCode        — 등록 코드
ParseSystemRegisterCodeEx      — 등록 코드 확장
ParseSystemRegisterTime        — 등록 시간
ParseSystemRegisterTimeEx      — 등록 시간 확장
ParseSystemGnssIOID            — GNSS IO ID
ParseSystemGnssDiffType        — GNSS 보정 타입
ParseSystemAdaptiveWorkMode    — 적응형 작업 모드
```

### 4.3 무선/네트워크 파싱

```
ParseRadioFreq / Power / AirBaud / Callsig / Fec / Module / Protocol
ParseRadioSensitivity / Stepper / InfoList
ParseNetLinkAccount / Apn / IpAddp / ServerType / DataSourceEx
ParseModemDialParams / ParseBandMode3G / ParseCsdPara3G
ParseDialPara3G / ParseWorkMode3G / ParseDataLinkOperatingMode
```

### 4.4 초기화 시퀀스 관련

```
SetInitConnect          — 초기 연결 설정
SetInitConnection       — 연결 초기화
SetInitNewConnect       — 새 연결
SetInitOldConnect       — 구형 연결
SetInitPartConnect      — 부분 연결
SetInitReceiver         — 수신기 초기화
```

### 4.5 파이프 관리 (RTK 커널 데이터 흐름)

```
ImuPipeConnect / Write / Close     — IMU 데이터 파이프
HcrxPipeConnect / Write / Close    — HRCx 데이터 파이프
RtcmPipeConnect / Write / Close    — RTCM 데이터 파이프
RtcmExPipeConnect / Write / Close  — 확장 RTCM 파이프
```

---

## 5. CRC/체크섬 상세

### 5.1 CRC-32 (NovAtel 바이너리 프로토콜용)

```
다항식: 0xEDB88320 (반전)
구현: Em_Check::CalculateCRC32, Em_Data_Buffer::CalculateCRC32
룩업 테이블: 256 엔트리 (libGNSS.so 오프셋 0x002520c0)
용도: NovAtel 바이너리 프로토콜 검증, 데이터 버퍼 무결성
```

### 5.2 CRC-24Q (RTCM3용)

```
구현: Em_Check::CalculateCRC24, Em_Cycle_Data_Buffer::CalculateCRC24
용도: RTCM3 프레임 CRC 검증
```

### 5.3 XOR 체크섬 (NMEA용)

```
구현: Em_Check::Data_Check_Sum
용도: NMEA 문장 체크섬 ($....*XX)
```

### 5.4 X10 프로토콜 프레임

```
일반 명령/쿼리 프레임: CRC 없음 ← 확인됨
펌웨어 전송 패킷: Init_Business_Packet_CRC 사용
RTCM 릴레이: RTCM 자체 CRC24Q만 사용
```

---

## 6. RTCM 처리

### 6.1 Em_TrsMtPrlRTCM (27 메서드)

| 메서드 | RTCM 타입 | 내용 |
|--------|----------|------|
| `Decode_type1004` | 1004 | GPS L1/L2 관측 |
| `Decode_type1005` | 1005 | 기준국 좌표 |
| `Decode_type1006` | 1006 | 기준국 좌표 + 높이 |
| `Decode_type1012` | 1012 | GLONASS L1/L2 관측 |
| `Decode_type1019` | 1019 | GPS 궤도력 |
| `Decode_type1021~1027` | 1021-1027 | 좌표 변환 파라미터 |
| `Decode_type1033` | 1033 | 수신기/안테나 정보 |
| `checkRTCMData` | - | RTCM 스트림 검증 |
| `processClause` | - | RTCM 절 처리 |

### 6.2 libGNSSJNI.so RTCM 함수 (LandStar)

```
cgcodec_input_rtcm2          — RTCM 2 입력
cgcodec_input_rtcm3          — RTCM 3 입력
cgcodec_gen_rtcm3            — RTCM 3 생성
cgcodec_rtcm_decode_char     — 문자 단위 RTCM 디코딩
cgcodec_rtcm_encode_bybuf    — 버퍼 기반 RTCM 인코딩
cgcodec_GetGpsWeekFromRtcm   — RTCM에서 GPS 주 추출
decode_rtcm2                 — RTCM 2 풀 디코더
```

### 6.3 RTCM 릴레이 함수 체인

```
CHCGetCmdSendDiffDataToOEM (JNI)
  → Em_Gnss::Send_DiffDataToGnss(vector<STR_CMD>&, uint8_t*, uint32_t)
    → Em_Format_HuaceNav::Send_DiffDataToGnss(vector<STR_CMD>&, uint8_t*, uint32_t)
      → Em_CmdPaker_X10::Construct_Transfer_Packet(vector<STR_CMD>&, uint8_t*, uint16_t)
```

---

## 7. JNI 함수 카테고리 분류

### TerraStar (1,780개)

| 카테고리 | 함수 수 | 주요 기능 |
|---------|---------|----------|
| 명령 빌더 (Get_Cmd_*) | 205 | 수신기 명령 생성 |
| 게터 (Get_*) | 138 | 상태/설정 조회 |
| 세터 (Set_*) | 110 | 설정 변경 |
| 파서 (Parse*) | 84 | 응답 파싱 |
| 시스템 | 76 | 펌웨어, 리셋, 전원 |
| 무선 | 65 | 라디오, 주파수, 프로토콜 |
| 네트워크 | 89 | CORS, GPRS, 모뎀 |
| 파일/기록 | 50 | PPK, 정적 측량 기록 |
| 블루투스 | 6 | BT MAC, BT 공유 |

### LandStar 추가분 (+700개)

| 카테고리 | 함수 수 | 비고 |
|---------|---------|------|
| SLAM/LiDAR | 208 | **신규** |
| 카메라 | 105 | **신규** |
| WiFi 공유 | 64 | **신규** |
| AR 지원 | 2 | **신규** |
| 전자 펜스 | 4 | **신규** |
| 클라우드/하트비트 | 6 | **신규** |
| HTTP 데이터 | 8 | **신규** |
| 타이머 전송 | 4 | **신규** |

---

## 8. 지원 OEM 보드 (14종)

| 보드 | 제조사 | 명령 빌더 | 응답 파서 |
|------|--------|----------|----------|
| **X10** | CHCNav | Em_CmdPaker_X10 | Em_RepParser_X10 |
| BD / BD380 | Trimble | Em_CmdPaker_BD | Em_RepParser_BD |
| NovAtel | NovAtel | Em_CmdPaker_NovAt | Em_ReptParser_NovAt |
| B380 | NovAtel | Em_CmdPaker_B380 | Em_ReptParser_B380 |
| UB4B0 | NovAtel | Em_CmdPaker_UB4B0 | Em_RepParser_UB4B0 |
| Unicore | Unicore | Em_CmdPaker_Unicore | Em_RepParser_Unicore |
| Hemisphere | Hemisphere | Em_CmdPaker_Hemis | Em_RepParser_Hemis |
| P307 | Hemisphere | Em_CmdPaker_P307 | Em_RepParser_P307 |
| u-blox 6T | u-blox | Em_CmdPaker_UBLox_6T | Em_RepParser_UBLox_6T |
| u-blox 8T | u-blox | Em_CmdPaker_UBLox_8T | Em_RepParser_UBLox_8T |
| u-blox F9P | u-blox | Em_CmdPaker_F9P_PDA | Em_RepParser_F9P_PDA |
| M620 | CHC | Em_CmdPaker_CHC_M620 | Em_RepParser_CHC_M620 |
| Taidou | Taidou | Em_CmdPaker_Taidou | Em_RepParser_Taidou |
| MengXin | MengXin | Em_CmdPaker_MengXin | Em_RepParser_MengXin |

---

## 9. 핵심 데이터 구조체

JNI 접근자에서 추론된 구조체:

### HC_ACCOUNT_STRUCT
```c
struct HC_ACCOUNT_STRUCT {
    char username[...];
    char password[...];
    // CORS/NTRIP 계정 정보
};
```

### HC_GNSS_BASE_SET_STRUCT
```c
struct HC_GNSS_BASE_SET_STRUCT {
    double latitude;
    double longitude;
    double height;
    int mode;          // 기지국 모드
    // 기지국 설정
};
```

### HC_IP_ADDRESS_STRUCT
```c
struct HC_IP_ADDRESS_STRUCT {
    char host[...];
    int port;
    // 서버 주소
};
```

### BlockInfo
```c
struct BlockInfo {
    uint8_t category;      // 명령 카테고리 (0x0a, 0x0b, 0x0e, ...)
    uint8_t subCmd_major;  // 서브 명령 (major)
    uint8_t subCmd_minor;  // 서브 명령 (minor)
    uint8_t* params;       // 파라미터 데이터
    uint16_t paramLen;     // 파라미터 길이
};
```

### STR_CMD
```c
struct STR_CMD {
    uint8_t* data;         // 패킷 데이터
    uint32_t length;       // 데이터 길이
};
```

---

## 10. NMEA 명령어

### 표준 NMEA
```
$GPGGA, $GPRMC, $GPGSA, $GPGSV
$GLGSV, $GAGSV, $GIGSV, $GQGSV
$GLGSA, $GAGSA, $BDGSA, $GBDGSV
$GNGST, $GPGST
$GTIMU (IMU 데이터)
```

### Hemisphere JASC 명령
```
$JASC,CMR,0/1          — CMR 활성화/비활성화
$JASC,GPGGA,1          — GGA 출력
$JASC,RTCM,0           — RTCM 비활성화
$JASC,RTCM3,0/1        — RTCM3 활성화/비활성화
$JBIN,3/35/36/65/...   — 바이너리 메시지
$JBAUD,                 — 보드레이트 설정
$JDIFF,RTK/BEACON/...  — 보정 모드 설정
$JMODE,BASE,YES/NO     — 기지국 모드
$JRESET / $JSAVE       — 리셋 / 저장
$JRTCM3,EXCLUDE/INCLUDE,MSM4  — MSM4 제외/포함
```

### Unicore 명령
```
$CCCAS,1,5             — CAS 설정
$CCCFG,1               — 설정
$CCMSG,GST,1,1,        — 메시지 설정
$CCSIR,                 — SIR 조회
$CFGMSG,0,2/3/4,1      — 메시지 설정
```

### OEM 보드 텍스트 명령 (HCNP를 통해 전달)
```
INTERFACEMODE COM2 RTCMV3 NOVATEL   — COM2 입력=RTCMV3, 출력=NOVATEL
interfacemode com2 unicore rtcmv3 on — Unicore 변형
LOG COM2,GPGGA,ONTIME 1              — 1초마다 GGA
unlogall com%d                        — COM 포트 로깅 중지
SAVECONFIG                            — 설정 저장
```

---

## 11. 인증/라이선스 시스템

```
CHCEncryptionRequest           — 암호화/활성화 요청
HC_REGISTER_CODE_STRUCT        — 등록 코드 구조체
HC_REGISTER_TIME_STRUCT        — 등록 시간 구조체
ParseSystemRegisterCode / Ex   — 등록 코드 파싱
ParseSystemRegisterTime / Ex   — 등록 시간 파싱
RegValidator::getExpireDate    — 만료일 확인
Get_Cmd_Set_SNKey              — 시리얼 키 설정
```

**RTCM 릴레이에는 인증 불필요** — `CHCGetCmdSendDiffDataToOEM`은 인증 체크 없이 raw 데이터를 감싸기만 함.

---

## 12. NTRIP 클라이언트

```
User-Agent: NTRIP GNSSInternetRadio/1.4.5    — 내장 User-Agent
SOURCETABLE 200 OK                            — 마운트포인트 테이블 응답
CtclibVrsIntegrityConvert/Copy/Free/Malloc    — VRS 무결성 함수
GetVrsIntegrityDDIonEstimate                  — VRS 전리층 추정
ctclib_rtktc_addvrs_integrity                 — VRS 무결성 추가
```

---

## 13. LandStar 8.2 신규 기능 (TerraStar 7.3 대비)

### SLAM/LiDAR (208 함수)
- 프로젝트 관리: 생성, 삭제, 이름변경, 제어, 상태
- VLiDAR 샘플링: U/V/타임스탬프, 위도/경도/고도/거리/정확도
- 저장소 관리: eMMC/TF 카드 용량 모니터링
- 씬 관리: 씬 리스트, 스트림 정보 (포트, 프로토콜, 타입)
- 알고리즘 상태: 진행률, 오류, 실행 상태
- 행렬 변환: 4x4 프로젝트 행렬
- 원점 좌표: 위도/경도/높이 + 쿼터니언 (QuatW/X/Y/Z) + XYZ

### 카메라 (105 함수)
- 기기정보: 모델, SN, HW/SW 버전, 센서 크기, 초점거리
- 해상도: 수평/수직/프레임레이트 쌍
- 파라미터: 최소/최대/현재값, 셔터 모드/시간, 컬러 모드
- 왜곡 보정: 내부/외부 파라미터 행렬, 방사/접선 왜곡 계수

### 기타 신규
- AR 지원 (`CHCGetARSupport`)
- 고급 기지국 (`advancedBaseStationSupported`)
- WiFi 공유 (`wifiShareSupported`)
- BT 네트워크 공유 (`Get_BT_Net_Share_Support`)
- 전자 펜스 (`Electronic_Fence`)
- 솔루션 모드 (`Solution_Mode`)
- 시스템 설정 점검 (`System_Setup_Check`)
- 클라우드 하트비트 (`Cloud_Heatbeat_Info`)
- HTTP 데이터 교환 (`BTHttpData`)
- 비밀번호 강제 변경 (`Must_Updata_Password`)
- 사용자 행동 수집 (`User_Behavior_Collect_Information`)
- 타이머 전송 (`Timer_Send_Info`)
- 펌웨어 업데이트 상태 조회

---

## 14. RTK 커널 (libGNSSJNI.so, LandStar만)

CHCNav 독점 `ctclib_*` 라이브러리.

### 핵심 기능
- **RTK 처리**: 정수 모호성 해결 (Integer Ambiguity Resolution)
- **INS/IMU 타이트 커플링**: EKF 기반 GNSS/INS 통합
- **다중 위성 시스템**: GPS, GLONASS, BeiDou, Galileo, QZSS, IRNSS/NavIC, SBAS
- **VRS 무결성**: 전리층 추정, 무결성 모니터링
- **RTCM 2/3 코덱**: 완전 인코딩/디코딩
- **PPP 지원**: `usePPP` 메서드
- **EKFSPP**: EKF 단독 측위
- **로버스트 추정**: 잔차 체크, 이상치 검출

### IMU/INS 관련
- IMU 오차 모델: 가속도계/자이로 바이어스, 스케일 팩터, 크로스 커플링
- EKF: 최대 120 위성
- ZARU (Zero Angular Rate Update)
- NHC (Non-Holonomic Constraint)
- 오도미터 지원
- IMU 캘리브레이션: 정적/비감지 캘리브레이션
- 속도 기반 헤딩 정렬

### JNI 인터페이스 (15 함수)
```
InitRTK / EndRTK / RunRTK       — RTK 엔진 제어
GetVarRTK / SetVarRTK            — RTK 변수 조회/설정
GetRTKKernelVersion / Str        — 커널 버전
InitResultDecoder / EndResultDecoder / DecodeResult  — 결과 디코딩
SendResultFIFODefault             — FIFO 결과 전송
InitGNSSSDK / EndGNSSSDK         — SDK 초기화/종료
ReadResult / WriteData            — 데이터 입출력
```

---

## 15. 프로토콜 명령 카테고리 종합

### X10 명령 처리기

| 카테고리 코드 | 처리기 | 내용 |
|-------------|--------|------|
| HC_3G | `Prc_Cmd_HC_3G` | 3G 모뎀 |
| HC_CAMERA | `Prc_Cmd_HC_CAMERA` | 카메라 (LandStar만) |
| HC_COM | `Prc_Cmd_HC_COM` | 시리얼 포트 |
| HC_DataLink | `Prc_Cmd_HC_DataLink` | 데이터 링크 |
| HC_File_Record | `Prc_Cmd_HC_File_Record` | 파일 기록 |
| HC_GNSS | `Prc_Cmd_HC_GNSS` | GNSS (핵심) |
| HC_Net | `Prc_Cmd_HC_Net` | 네트워크 |
| HC_Radio | `Prc_Cmd_HC_Radio` | 무선 |
| HC_SLAM | `Prc_Cmd_HC_SLAM` | SLAM (LandStar만) |
| HC_SYSTEMSTATUS | `Prc_Cmd_HC_SYSTEMSTATUS` | 시스템 상태 |
| HC_System | `Prc_Cmd_HC_System` | 시스템 |
| HC_WIFI | `Prc_Cmd_HC_WIFI` | WiFi |

### 초기화 명령에서 사용되는 파라미터 ID 종합

| 파라미터 ID | 네이티브 함수 | 값 | 의미 |
|------------|-------------|-----|------|
| 03,06 | `HC_CMD_ID_SYSTEM_FIRMWARE_VERSION` | (조회) | 펌웨어 버전 |
| 03,0c | `IODiffType` | (조회) | 보정 프로토콜 타입 |
| 03,11 | `IOEnable` | 0x01 | 보정 입력 활성화 |
| 03,14 | `HC_CMD_ID_SYSTEM_HARDWARE_INFO` | (조회) | 하드웨어 정보 |
| 03,18 | `HC_CMD_ID_SYSTEM_RECEIVER_MODE` | (조회) | 수신기 모드 |
| 03,20 | `DiffModule` | 0x02 | RTK 모드 |
| 04,04 | (블록 마커) | - | 서브 파라미터 블록 |
| 04,10 | (설정) | 0x09 | 포트 설정 |
| 04,30 | `IOConnect` | 0x09 | 보정 포트 = BT SPP |
| 04,50 | (데이터 형식) | 0x06 | 데이터 라우팅 형식 |
| 04,51 | (IO 매핑) | 0x0a | IO 라우트 엔트리 |
| 04,52 | `DataRouting` | (26B) | IO 라우팅 테이블 |
| **04,54** | (RTCM 브로드캐스트) | **0x23** | **RTCMV3 형식** |
| **04,5a** | (IO 보정 소스) | **0x01** | **BT 보정 입력 활성화** |
| 04,5b | (보정 포트 래퍼) | - | 04,30 래퍼 |
| 07,11 | `SatInfo` | (조회) | 위성 추적 정보 |
| 07,19 | `ConstEnable` | (조회) | 위성 시스템 활성화 |
| **15,04** | `DataLink_Differential_Data` | (RTCM) | **RTCM 보정 데이터 릴레이** |
