# BTB M=4 N:M + 특수값 곱셈 우회 통합 RTL

`rtl/`의 여섯 v파일을 함께 사용한다. 원본 및 이전 N:M 배포본은 수정하지 않았다. `reference_rtl/`은 최초 dense 원본, `reference_nm4/`는 직전 N:M 복사본이다. 기존 모듈·변수명·누산 구조를 유지했다.

## 실제로 통합한 내용

- K축 M=4, NNZ capacity mode 0:4 / 1:4 / 2:4 / Dense, 무손실 bitmap을 유지한다.
- A는 nonzero 1bit/행, B는 ZERO/MUL/PASS/NEG/SHIFT를 담는 4bit/열로 전달한다.
- B=+1은 A 전달, B=-1은 부호 반전, B=2/4/8/16/32/64는 shift로 계산한다. +1과 shift0을 중복 계산하지 않는다.
- 나머지 nonzero는 기존 signed INT8 곱셈을 사용한다. A를 16bit로 확장한 뒤 negate/shift하므로 -128×-1=+128도 정확하다.
- 일반 곱셈 경로를 선택하지 않으면 multiplier의 두 입력을 0으로 차단한다. 누산·출력 폭은 signed INT32 그대로다.
- 2bit 조각 단위의 부분곱 slicing, 2^n-1 대체, 음의 -2^n 대체는 추가하지 않았다. 값 payload와 외부 memory read/write는 유지한다.

## 4bit B 작업 태그

| 값 | binary / hex | 동작 |
|---|---|---|
| 0 또는 invalid column | 0000 / 0 | ZERO |
| 그 외 일반값 | 0001 / 1 | MUL |
| +1 | 0010 / 2 | PASS |
| -1 | 0011 / 3 | NEG |
| +2 | 1001 / 9 | SHL1 |
| +4 | 1010 / A | SHL2 |
| +8 | 1011 / B | SHL3 |
| +16 | 1100 / C | SHL4 |
| +32 | 1101 / D | SHL5 |
| +64 | 1110 / E | SHL6 |

SHIFT 태그의 하위 3bit가 지수다. 4..8,F는 예약이며 classifier는 생성하지 않는다. -128은 raw bit가 한 개만 1이어도 signed 양수 128이 아니므로 MUL이다. -2도 이번 범위에서는 MUL이다.

총 10개 상태이므로 고정폭 operand 태그는 최소 4bit가 필요하다. 4×4에서는 A_nz 4bit+B_tag 16bit=**20bit 실행 제어**다. 이전 제안의 A/B nz 8+class 8+지수 12=28bit보다 28.57% 적다. 별도 B_nz는 tag에서 복원하므로 중복 저장하지 않는다. 원래 값, rows/cols, K/first/last, 그룹 descriptor는 별도이며 전체 인터페이스가 20bit라는 뜻은 아니다. B만 분류해 열마다 공유하므로 A/B 중 어느 쪽이 특수값인지 고르는 mux와 A tag는 필요 없다.

## work_mask와 mode 구분

```verilog
work_mask[r*PE_COLS+c] = out_a_nz[r] && (out_b_tag[4*c +: 4] != 0);
```

`work_mask`는 한 K에서 PE별 실행 여부를 펼친 기존 호환·검증용 신호다. 통합 MAC은 `op_a_nz`, `op_b_tag`를 실행 제어에 사용한다. `op_b_nz` 포트는 legacy 호환용이며 SPECIAL_OPS=1에서는 사용하지 않는다.

`group_mask_a[4*r+q]`와 `group_mask_b[4*c+q]`는 K축 네 위치의 nonzero bitmap이다. `group_mode_a/b`의 2bit는 NNZ capacity 정보이며 4bit 작업 tag와 구분한다. `op_rows/op_cols`는 출력 C가 존재하는지 나타내며 zero mask로 덮어쓰지 않는다. first는 항상 초기화하고 last는 모든 유효 C를 출력한다.

## 변경 파일과 주요 변수

| 파일 | 상태 | 설명 |
|---|---|---|
| sparsity_frontend.v | 수정 | classify_b, b_tag, out_b_tag 추가. B_nz는 tag!=0에서 복원. 값과 tag를 같은 elastic packet에 저장 |
| mac_array.v | 수정 | op_b_tag, SPECIAL_OPS, is_pass/is_neg/is_shift, a_ext, mul_enable/mul_a/mul_b/general_product, 경로별 event 추가 |
| gemm_top.v | 수정 | cb_tag 연결, SPECIAL_OPS 전달, 경로별 event 외부 출력 |
| gemm_control.v | 원본 동일 | 스케줄·주소·완료 유지 |
| operand_loader.v | 원본 동일 | scalar read 유지 |
| result_writer.v | 원본 동일 | 결과 write 유지 |

`product`는 각 경로를 선택한 16bit 곱셈 결과, `next_sum/acc`는 기존 32bit 누산이다. `mul_enable`은 valid·유효 PE·실행 enable이 있고 fast 경로가 아닐 때만 1이다. `mul_a/mul_b`는 일반 곱셈기에 실제로 들어가는 입력이다. `event_mac`은 nonzero 곱셈-누산 항 전체이고 `event_mul/pass/neg/shift`는 그 항의 실행 경로다. 네 event의 합은 event_mac 수와 같다. 경로가 바뀌어도 누산 수는 줄지 않는다.

`out_k/ck`는 원래 K index, `current_pos/group_pos`는 M=4 내부 위치다. `packet_hold`는 원래 값·A_nz·B_tag·K·경계·그룹 정보를 함께 저장하며 기본 4×4에서 PACKET_W=162bit, valid 별도 1bit다. 이는 실행 제어 20bit나 합성 후 FF 총량과 다른 수치다.

## 설정과 통합 계약

| 파라미터 | 기본 | 의미 |
|---|---:|---|
| SPECIAL_OPS | top 1 / standalone MAC 0 | 1은 fast 경로와 tag 제어, 0은 일반 곱셈 대조군 |
| MASK_PIPELINE | 1 | 1단 elastic register. 0은 조합 bypass |
| SKIP_EMPTY | 0 | 모든 K 보존. 1이면 first/last/group-end를 제외한 중간 empty 생략 |
| FACTORED_MASK | top 1 / standalone MAC 0 | 1은 A/B 분리 제어, 0은 legacy work_mask |

standalone MAC에서 SPECIAL_OPS=1을 쓸 때 FACTORED_MASK=1과 올바른 tag를 함께 연결한다. 모든 payload는 valid=1,ready=0 동안 유지한다. 기본 설정은 K packet 수를 유지한다. skip을 켠 Compute는 원래 K를 수신 순번으로 추정하면 안 된다. `nm_valid`는 Compute가 그룹 끝을 수락한 cycle의 관측 event이며 별도 backpressure 인터페이스가 아니다.

## 검증과 성과

[REPORT.md](REPORT.md)에 실제 수치와 합성 상태를 기록한다. 21종 입력, 다섯 설정, 총 125회 시스템 회귀가 모두 PASS다. bypass/pipeline/skip 각각 65,536개 signed INT8 쌍, 16×16 위치 mask 조합, K tail, random stall, reset, II=1을 검증했다. 경로별 event는 독립 Python 모델과 대조했고 미선택 multiplier 입력이 0인지 RTL assertion으로 확인했다.

nonzero 판정은 논리 MAC 실행 수를 줄인다. 특수값 우회는 그 이후 남은 일반 곱셈을 전달·반전·shift로 대체한다. 전체 실행 cycle·전력 감소율과 동일하지 않다. 현재 read 수는 그대로이며 실제 전력은 측정하지 않았다.

## 재현

작업 폴더에서 Python 3와 Vivado 2022.2를 사용한다. `C:/btb_build`는 쓰기 가능한 영문 절대 경로 예시다.

```powershell
python scripts/run_tests.py --build-root C:/btb_build
python scripts/run_units.py --build-root C:/btb_build
python scripts/run_synth.py --build-root C:/btb_synth --part xc7s50csga324-1
python scripts/analyze.py
python scripts/make_report.py
```

결과·입력·source hash는 results/에 있다. changes_from_original.diff와 changes_from_nm4.diff를 함께 제공한다. 합성은 설치된 Spartan-7 기준으로 비교하며 최종 ASIC/보드 타이밍을 보장하지 않는다. Vivado 2022.2 내부 초기화가 실패하면 해당 실패를 PASS로 처리하지 않고 원래 로그를 남긴다.
