# BTB Set 4 열별 N:4 압축 발행

기존 `BTB_Set4_Integrated`의 로더에서 A·B 패킷을 받아, 스파시티가 열별로 실행할 K 위치를 선택한다. Vivado 프로젝트에 `rtl/*.v` 여섯 파일을 추가하고 `gemm_top`을 top으로 설정한다.

| 수정한 RTL | 역할 |
| --- | --- |
| `sparsity_frontend.v` | ACC별 A와 공유 B의 K 그룹을 두 버퍼에 교대로 모은다. B 열별 모드와 위치로 A·B·특수값 태그를 고르고, 같은 라운드 안에서 Set 4 ACC 순서로 MAC에 전달한다. |
| `mac_array_compute_v2.v` | `A_PER_COLUMN`으로 A 입력을 기본 공유 32비트 또는 열별 128비트로 선택한다. PE 입력과 이벤트 집계에 해당 열의 A를 연결한다. 압축 경로는 기존 PE별 `work_mask`를 사용한다. |
| `gemm_top.v` | 열별 A와 기존 실행 마스크를 연결한다. N:4 관측 이벤트를 스파시티에서 직접 받아 생략한 0:4 그룹의 정보도 전달한다. |

압축 실행에서 K 그룹은 B 한 열의 연속 네 위치다. 기본 구성에서 한 버퍼가 A 64바이트와 B 16바이트를 저장한다. 0·1·2:4 열은 살아 있는 K만 선택하며, Dense 열은 유효한 K 전체를 순회한다. 그룹의 발행 라운드 수는 열별 실행 길이의 최댓값이다. 중간 0:4 그룹은 발행을 생략한다. 0:4가 첫 그룹이나 마지막 그룹에 오면 실행 마스크가 0인 라운드로 초기화 또는 결과 전달을 처리한다. 첫·마지막이 같은 그룹이면 한 라운드에서 두 경계를 처리한다.

ACC 선택·누산·특수값 연산은 기존 Compute v2를 사용한다. `gemm_control.v`, `operand_loader.v`, `result_writer.v`는 기존 파일과 바이트 단위로 일치한다. 외부 메모리와 C 출력 포트 계약은 기존 Set 4를 따른다.

## 재현

Python 3과 Vivado Simulator 2022.2로 실행한다. `--build`에는 쓰기 가능한 영문 경로를 지정한다.

```powershell
$runner = 'output/BTB_Set4_NM4_Packed/run.py'
$vivado = 'C:/Xilinx/Vivado/2022.2/bin'
$cases = 'html_20x12x8','html_8x8x4','html_19x11x7','html_64x128x128'
python $runner --vivado-bin $vivado --build C:/Temp/btb_set4_original --baseline-rtl output/BTB_Set4_Integrated/rtl --cases @cases
python $runner --vivado-bin $vivado --build C:/Temp/btb_set4_packed
```

비교 입력은 메모리팀 HTML의 기본 B 2:4 생성 규칙과 네 가지 행렬 크기를 사용한다. `compute_packets`는 MAC이 수락한 패킷 수, `cycles`는 완료까지의 RTL 사이클, `xsim_wall_s`는 PC에서 시뮬레이터가 실행된 시간이다. 테스트벤치 클록 주기는 10 ns다.

## 비교 결과

| M × N × K | MAC 패킷 기존 → 압축 | 전체 사이클 기존 → 압축 | RTL 시간 기존 → 압축 |
| --- | ---: | ---: | ---: |
| 20 × 12 × 8 | 120 → 60 | 905 → 880 (-2.76%) | 9.05 → 8.80 µs |
| 8 × 8 × 4 | 16 → 8 | 237 → 240 (+1.27%) | 2.37 → 2.40 µs |
| 19 × 11 × 7 | 105 → 60 | 775 → 744 (-4.00%) | 7.75 → 7.44 µs |
| 64 × 128 × 128 | 65,536 → 32,768 | 205,567 → 204,002 (-0.76%) | 2055.67 → 2040.02 µs |

두 버전과 앞선 HTML 실험에서 A·B·C 및 설정 파일의 해시가 일치했다. 비교한 네 입력에서 모든 C 원소, 외부 A/B 읽기 수, nonzero 곱셈·누산 항 수가 일치했다. 압축본은 일반 입력과 지연, 재시작, 0:4 생략, 1:4 및 Dense 전환을 포함한 30개 케이스 35회를 통과했다.

8 × 8 × 4에서는 첫 MAC 수락이 30 → 150사이클로 늦어졌다. 그룹을 채우는 초기 대기가 생기고, 발행 수를 줄인 뒤에도 외부 읽기와 C 쓰기가 이어진다. 표의 시간은 10 ns 테스트벤치 기준이며 FPGA 배선 후 동작 주파수는 측정하지 않았다.

원시 비교값은 `results/comparison.csv`에 있고, 압축본 전체 결과는 `results/packed_regression.csv`에 있다.
