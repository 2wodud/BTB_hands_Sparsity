# Sparsity B Packet · 1119

Set 4 로더에서 받은 A·B를 K 네 위치씩 모으고, B 열마다 필요한 K를 골라 압축 발행하는 스파시티 RTL이다. 이번 버전은 MAC팀 전달용 8비트 K 선택 출력 `out_k_mask`를 추가했다.

## 먼저 보기

[입력 → 처리 → 출력 설명 HTML](index.html)을 내려받아 브라우저에서 연다. 파일 하나로 오프라인 실행할 수 있다. GitHub 파일 화면의 **Download raw file**로 저장하면 된다.

- **재생**으로 선택 그룹의 입력 수집부터 ACC·라운드별 MAC 발행까지 본다. 일시정지와 속도 조절을 지원한다.
- A·B 값을 직접 수정하면 위치 비트맵, 모드, K 선택, B 태그, PE 마스크가 함께 바뀐다.
- 출력 열을 선택하면 해당 A·B의 원본 위치를 강조한다.
- 입력값은 메모리팀 `BTB_스케줄링_비교.html`의 `makeInput()` 규칙을 사용한다.
- 재생 단계는 패킷 처리 순서를 설명한다. 실제 사이클은 아래 Vivado 결과에서 확인한다.

## 구성

```text
Sparsity_B_Packet_1119/
├── README.md
├── index.html
├── rtl/                         # 통합 RTL 여섯 파일
├── tb/                          # 정답·핸드셰이크·ACC·메타데이터 검사
├── run.py                       # Vivado 시스템 회귀 실행
├── docs/A_SELECTION_AGREEMENT.md # A 선택 담당·그룹 전달 합의사항
└── results/
    ├── comparison.csv           # 기존 Set 4와 압축 경로 비교
    └── integration_summary.csv  # K 출력 추가본의 시스템 회귀 결과
```

| RTL | 역할 |
| --- | --- |
| `sparsity_frontend.v` | 두 그룹 버퍼, nonzero 비트맵, 모드·특수값 태그, 열별 K 선택, PE 마스크, K 8비트 출력 |
| `operand_loader.v` | Set 4의 A/B 재사용 버퍼, 같은 K의 ACC 간 B 공유 |
| `gemm_control.v` | Set 4의 열 그룹·행 블록·열 타일·K·ACC 순회와 C 주소 관리 |
| `mac_array_compute_v2.v` | 열별 A 입력을 받는 Compute v2 검증 경로, 특수값 연산과 ACC 누산 |
| `result_writer.v` | 유효 C 원소의 주소·데이터 출력 |
| `gemm_top.v` | 위 모듈을 연결하는 기존 압축 발행 검증용 top |

기본 검증 구성은 PE 4×4, signed INT8 입력, signed INT32 결과, 4 ACC, 로더 4슬롯이다. 로더·제어·writer는 `BTB_Set4_Integrated`의 Set 4 원본을 사용한다.

## 스파시티의 처리 순서

```mermaid
flowchart LR
    A["Set 4 로더<br/>같은 K에서 ACC 순회"] --> B["두 그룹 버퍼<br/>ACC별 A · 공유 B"]
    B --> C["B 열별 위치 비트맵<br/>0·1·2:4 / Dense"]
    C --> D["열마다 K 선택<br/>같은 K의 A·B·태그 조회"]
    D --> E["압축 MAC 패킷<br/>A · B · K 8bit · PE 마스크"]
```

1. 각 ACC의 K를 추적해 A·B를 연속 K 네 위치의 그룹으로 모은다. 한 슬롯을 발행하면서 다른 슬롯에 다음 그룹을 수집할 수 있다.
2. 각 B 열의 nonzero 위치를 4비트로 저장하고 그 개수로 모드를 정한다.
3. 각 열이 이번 라운드에 실행할 K를 고른다. 그 K의 A 벡터·B 값·태그를 함께 선택한다.
4. 선택한 A와 B가 모두 nonzero인 PE의 실행 마스크를 1로 만든다.
5. 한 라운드에서 활성 ACC를 순서대로 방문한다. 패킷 수락 후 다음 ACC·라운드로 진행한다.

로더 슬롯 4개는 전송 중인 패킷을 저장한다. 같은 K의 ACC 0~3 패킷으로 찰 수 있다. N:4는 B 한 열의 K 네 위치를 묶는 규칙이며, 별도 스파시티 그룹 버퍼에서 수집한다.

## 모드와 발행 횟수

| B 한 열의 nonzero 수 | 모드 | 열별 실행 |
| --- | --- | --- |
| 0 | 0:4 | 계산 항 없음 |
| 1 | 1:4 | 해당 K 한 위치 |
| 2 | 2:4 | 해당 K 두 위치를 작은 K부터 선택 |
| 3~4 | Dense | 유효 K 전체를 순회하고 0인 항은 마스크로 차단 |

그룹의 라운드 수는 네 열의 실행 길이 중 최댓값이다. 예를 들어 열별 모드가 0:4·1:4·2:4·1:4이면 두 라운드다. Dense 열이 포함된 완전한 그룹은 네 라운드를 사용한다. 마지막 그룹은 실제 유효 K 길이를 따른다.

모든 B가 0인 중간 그룹은 MAC 발행을 생략한다. 타일의 첫·마지막 그룹은 0 마스크 패킷으로 ACC 초기화·C 출력을 처리한다. 같은 그룹이 첫·마지막이면 한 라운드로 처리한다.

## 8비트 K 선택 인터페이스

| 필드 | 해당 B 열 | 의미 |
| --- | --- | --- |
| `out_k_mask[1:0]` | 0열 | 그룹 내부 K 위치 0~3 |
| `out_k_mask[3:2]` | 1열 | 그룹 내부 K 위치 0~3 |
| `out_k_mask[5:4]` | 2열 | 그룹 내부 K 위치 0~3 |
| `out_k_mask[7:6]` | 3열 | 그룹 내부 K 위치 0~3 |

그룹 시작 K는 `out_k`다. 원래 K는 `out_k + out_k_mask[2*c +: 2]`로 계산한다. 0~3열의 선택이 각각 0, 3, 2, 1이면 `out_k_mask=8'b01_10_11_00`이다.

`out_k_mask`는 선택한 B·태그·A·마스크와 같은 패킷이며, `out_valid && out_ready`일 때 수락한다. valid=1·ready=0 동안 데이터와 발행 위치를 유지한다.

항이 없는 열은 K 필드 00, B=0, B 태그 ZERO, 해당 PE 실행 마스크=0이다. 유효 K=0도 K 필드 00을 사용하므로 태그·실행 마스크로 실행 여부를 판정한다.

| 주요 출력 | 기본 폭 | 배치 |
| --- | --- | --- |
| `out_a` | 128 bit | 열 c, 행 r는 `[32*c + 8*r +: 8]` |
| `out_b` | 32 bit | 열 c는 `[8*c +: 8]` |
| `out_b_tag` | 16 bit | 열 c는 `[4*c +: 4]` |
| `work_mask` | 16 bit | 행 r, 열 c는 `[4*r+c]` |
| `out_k_mask` | 8 bit | 열 c는 `[2*c +: 2]` |
| `out_bank` | 2 bit | 현재 ACC 번호 |
| `out_first/out_last` | 각 1 bit | 타일 초기화·최종 결과 처리 |
| `out_rows/out_cols` | 각 4 bit | 실제 유효한 C 행·열 |

B 태그는 ZERO=0, MUL=1, PASS(+1)=2, NEG(-1)=3, SHL1~SHL6=9~E를 사용한다. -128과 나머지 일반 nonzero 값은 MUL이다.

## A 선택과 top 연결 상태

현재 스파시티는 K에 맞춰 선택한 A를 `out_a`로 제공한다. 포함된 top·Compute v2는 이 A를 받는 검증 경로이며 `A_PER_COLUMN=1`, `FACTORED_MASK=0`, `PE_Folding=0`을 사용한다.

새 `out_k_mask`는 스파시티 출력 포트에 추가돼 있다. 포함된 `gemm_top.v`에는 이 포트를 MAC팀 K 입력으로 연결하는 배선이 아직 없다. MAC팀 top에서 `.out_k_mask(b_k_mask)`를 연결하고 실제 MAC 입력 이름에 맞춰 전달해야 한다.

MAC이 A 선택을 맡는 경우에는 A 그룹이 MAC 버퍼에 먼저 준비돼야 한다. 그룹 전달 경로와 폭, ACC·그룹 식별, 저장 완료와 교체 시점, A nonzero 판정 담당을 합의한다. 자세한 내용은 [A 선택 인터페이스 합의사항](docs/A_SELECTION_AGREEMENT.md)에 있다.

`out_group_end`는 생략된 중간 0:4 그룹에서도 발생하는 그룹 관측 이벤트다. A 그룹 저장용 핸드셰이크로 연결할 때는 별도 수락 규약이 필요하다.

## Vivado 검증과 측정

- K 출력 단독 검사에서 64개 그룹이 통과했다. K 길이 1~4, B 위치 패턴, 선택 K·A·B·태그·마스크의 정합성과 출력 정체를 검사했다.
- 이 폴더와 같은 RTL 여섯 파일을 기존 top·Compute v2로 시스템 검사해 7개 케이스·12회 실행이 통과했다. HTML 네 입력과 모드 전환, K 끝부분·ACC, reset·재시작을 포함한다.
- 시스템 결과는 [integration_summary.csv](results/integration_summary.csv), 기존 대비 수치는 [comparison.csv](results/comparison.csv)에 있다.

메모리팀 HTML의 기본 B 2:4 패턴, 같은 A·B·C 정답, Vivado XSIM 2022.2와 10 ns 클록으로 비교했다.

| M × N × K | MAC 발행 기존 → 압축 | 전체 사이클 기존 → 압축 | 실행 PE 항 수 · 두 방식 동일 | RTL 시간 기존 → 압축 |
| --- | ---: | ---: | ---: | ---: |
| 20 × 12 × 8 | 120 → 60 | 905 → 880 | 924 | 9.05 → 8.80 µs |
| 8 × 8 × 4 | 16 → 8 | 237 → 240 | 128 | 2.37 → 2.40 µs |
| 19 × 11 × 7 | 105 → 60 | 775 → 744 | 706 | 7.75 → 7.44 µs |
| 64 × 128 × 128 | 65,536 → 32,768 | 205,567 → 204,002 | 507,328 | 2,055.67 → 2,040.02 µs |

MAC 발행은 입력 핸드셰이크 횟수, 실행 PE 항 수는 nonzero A×B의 곱셈·누산 항 수다. 외부 읽기량과 실제 계산 항 수는 두 방식에서 일치했다. 그룹 수집과 외부 읽기 대기도 전체 시간에 반영된다. 짧은 8×8×4에서는 그룹 수집으로 첫 MAC이 30→150사이클로 늦어져 완료가 3사이클 늘었다.

위 시스템 검증은 선택된 A를 받는 Compute v2 기준이다. MAC팀의 K 입력 기반 A 선택 구현과의 통합은 A 그룹 규약 합의 후 검사한다. 시간은 테스트벤치 기준이며 FPGA 배선 후 주파수는 측정 전이다.

## 재현

Vivado 설계 파일에는 이 폴더의 `rtl/*.v` 여섯 파일을 추가하고 `gemm_top`을 top으로 선택한다. 여러 배포본의 동명 모듈을 함께 추가하면 중복 선언이 생기므로 사용할 배포본의 RTL을 선택한다.

Python 3과 Vivado Simulator 2022.2를 사용한다. 아래 명령은 저장소 루트에서 실행하며, `--build`에는 쓰기 가능한 영문 경로를 지정한다.

```powershell
python Sparsity_B_Packet_1119/run.py --vivado-bin C:/Xilinx/Vivado/2022.2/bin --build C:/Temp/btb_packet_1119 --cases html_20x12x8 html_8x8x4 html_19x11x7 html_64x128x128 packed_modes banks_tail restart
```

`summary.csv`는 지정한 빌드 경로에 생성된다. `run.py`의 기본 실행은 30개 케이스이며, `--extended`로 추가 회귀를 선택할 수 있다.

## 원본 출처

Memory Set 4와 Compute v2의 기존 협업 구조를 기준으로 스파시티·열별 A 입력을 연결했다. 원본은 [Memory Set 4](https://github.com/angigpen/btb_memory_dataflow_team/tree/bd5868e3491e4696f958ca4a24b15edd7e2eb0fb/loader_only/set4), [Compute v2](https://github.com/leejunjunjun/BTB_GEMM_compute-pipeline/blob/3b004ff3d12b9921a746b98369f1b9e46dac3645/rtl/mac_array/mac_array_compute_v2.v)다.
