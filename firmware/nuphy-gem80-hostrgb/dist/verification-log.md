# Gem80 hostrgb — 하드웨어 검증 로그

- 일시: 2026-09-10T01:59:18Z (최초 플래시) ~ 2026-09-10T02:33:24Z (재플래시, 최종)
- 검증된 펌웨어(커밋됨): `nuphy_gem80_ansi_hostrgb.bin` (73684 bytes, sha256 332004230de77a088ed8188d9906fd1d09eba7788f3cf947a22adae08b8148e3) — `dist/build-info.json`과 일치
- 최초 플래시 펌웨어(재플래시로 대체됨): 73672 bytes, sha256 1a261a0eaade3051… — raw_hid_send 수정 전 빌드. 5단계에서 이 빌드를 먼저 플래시했으나 dfuMANIFEST에서 멈췄고(6단계), 조작자가 수정본으로 재플래시했다(재플래시 절 참고)
- 플래시 전 bcdDevice: 0118 (순정 v1.1.8)
- 백업: `QMK_firmware_nuphy_gem80_trimode_ansi_v2.1.5.bin` (VIA 키맵은 커스텀 없음으로 생략)

## 4단계 출처 게이트

통과 — fork SHA, make 타깃, 바이너리 sha256, 키맵 3해시 전부 일치.

## 5단계 플래시

```
dfu-util 0.11

Copyright 2005-2009 Weston Schmidt, Harald Welte and OpenMoko Inc.
Copyright 2010-2021 Tormod Volden and Stefan Schmidt
This program is Free Software and has ABSOLUTELY NO WARRANTY
Please report bugs to http://sourceforge.net/p/dfu-util/tickets/

Opening DFU capable USB device...
Device ID 0483:df11
Device DFU version 011a
Claiming USB DFU Interface...
Setting Alternate Interface #0 ...
Determining device status...
DFU state(10) = dfuERROR, status(10) = Device's firmware is corrupt. It cannot return to run-time (non-DFU) operations
Clearing status
Determining device status...
DFU state(2) = dfuIDLE, status(0) = No error condition is present
DFU mode device DFU version 011a
Device returned transfer size 2048
DfuSe interface name: "Internal Flash  "
Downloading element to address = 0x08000000, size = 73656
Erase   	[                         ]   0%            0 bytesErase   	[                         ]   0%            0 bytesErase   	[                         ]   2%         2048 bytesErase   	[=                        ]   5%         4096 bytesErase   	[==                       ]   8%         6144 bytesErase   	[==                       ]  11%         8192 bytesErase   	[===                      ]  13%        10240 bytesErase   	[====                     ]  16%        12288 bytesErase   	[====                     ]  19%        14336 bytesErase   	[=====                    ]  22%        16384 bytesErase   	[======                   ]  25%        18432 bytesErase   	[======                   ]  27%        20480 bytesErase   	[=======                  ]  30%        22528 bytesErase   	[========                 ]  33%        24576 bytesErase   	[=========                ]  36%        26624 bytesErase   	[=========                ]  38%        28672 bytesErase   	[==========               ]  41%        30720 bytesErase   	[===========              ]  44%        32768 bytesErase   	[============             ]  50%        36864 bytesErase   	[=============            ]  52%        38912 bytesErase   	[==============           ]  58%        43008 bytesErase   	[===============          ]  61%        45056 bytesErase   	[===============          ]  63%        47104 bytesErase   	[================         ]  66%        49152 bytesErase   	[=================        ]  69%        51200 bytesErase   	[==================       ]  72%        53248 bytesErase   	[==================       ]  75%        55296 bytesErase   	[===================      ]  77%        57344 bytesErase   	[====================     ]  80%        59392 bytesErase   	[====================     ]  83%        61440 bytesErase   	[=====================    ]  86%        63488 bytesErase   	[======================   ]  88%        65536 bytesErase   	[======================   ]  91%        67584 bytesErase   	[=======================  ]  94%        69632 bytesErase   	[======================== ]  97%        71680 bytesErase   	[=========================] 100%        73656 bytes
Erase    done.
Download	[                         ]   0%            0 bytesDownload	[                         ]   2%         2048 bytesDownload	[=                        ]   5%         4096 bytesDownload	[==                       ]   8%         6144 bytesDownload	[==                       ]  11%         8192 bytesDownload	[===                      ]  13%        10240 bytesDownload	[====                     ]  16%        12288 bytesDownload	[====                     ]  19%        14336 bytesDownload	[=====                    ]  22%        16384 bytesDownload	[======                   ]  25%        18432 bytesDownload	[======                   ]  27%        20480 bytesDownload	[=======                  ]  30%        22528 bytesDownload	[========                 ]  33%        24576 bytesDownload	[=========                ]  36%        26624 bytesDownload	[=========                ]  38%        28672 bytesDownload	[==========               ]  41%        30720 bytesDownload	[===========              ]  44%        32768 bytesDownload	[===========              ]  47%        34816 bytesDownload	[============             ]  50%        36864 bytesDownload	[=============            ]  52%        38912 bytesDownload	[=============            ]  55%        40960 bytesDownload	[==============           ]  58%        43008 bytesDownload	[===============          ]  61%        45056 bytesDownload	[===============          ]  63%        47104 bytesDownload	[================         ]  66%        49152 bytesDownload	[=================        ]  69%        51200 bytesDownload	[==================       ]  72%        53248 bytesDownload	[==================       ]  75%        55296 bytesDownload	[===================      ]  77%        57344 bytesDownload	[====================     ]  80%        59392 bytesDownload	[====================     ]  83%        61440 bytesDownload	[=====================    ]  86%        63488 bytesDownload	[======================   ]  88%        65536 bytesDownload	[======================   ]  91%        67584 bytesDownload	[=======================  ]  94%        69632 bytesDownload	[======================== ]  97%        71680 bytesDownload	[=========================] 100%        73656 bytes
Download done.
File downloaded successfully
Submitting leave request...
Transitioning to dfuMANIFEST state
```

플래시 성공: `Download done.` / `File downloaded successfully` / `Submitting leave request...` / `Transitioning to dfuMANIFEST state`.

관찰 두 가지:

- 첫 상태 조회에서 장치가 `dfuERROR, status(10) = Device's firmware is corrupt`를 반환했고 dfu-util이 상태를 지우고 진행했다. `Esc` 홀드 진입 시 앱이 깔끔하게 넘겨주지 않아 생기는 STM32 DFU의 알려진 특성이며, 오류가 아니다.
- `:leave` 요청 후에도 장치가 `0483:df11`로 남았다. `dfuMANIFEST` 이후 전원 재인가가 필요한 경우로, 재연결로 해소한다.

## 6단계 재열거

**중단 지점.** 플래시는 완료되었으나 장치가 `dfuMANIFEST` 상태로 남아 재열거되지 않았다. `dfu-util -e`는 `can't detach`를 반환한다 — STM32 ROM 부트로더는 이 상태에서 전원 재인가를 요구하며 소프트웨어 경로가 없다. USB 버스 장치 번호가 `Device 017`로 불변인 것이 물리적 분리가 아직 없었음을 보여준다.

이후 단계(재열거 확인, R6–R10 프로토콜 검증)는 조작자가 케이블을 재연결한 뒤 재개한다.

## 재플래시 (raw_hid_send 수정본)

- 일시: 2026-09-10T02:33:24Z
- 크기: 73684 bytes (DfuSe element 크기 73656 → 73668, raw_hid_send 호출 3개 추가)
- 출처 게이트: 통과

```
dfu-util 0.11

Copyright 2005-2009 Weston Schmidt, Harald Welte and OpenMoko Inc.
Copyright 2010-2021 Tormod Volden and Stefan Schmidt
This program is Free Software and has ABSOLUTELY NO WARRANTY
Please report bugs to http://sourceforge.net/p/dfu-util/tickets/

Opening DFU capable USB device...
Device ID 0483:df11
Device DFU version 011a
Claiming USB DFU Interface...
Setting Alternate Interface #0 ...
Determining device status...
DFU state(10) = dfuERROR, status(10) = Device's firmware is corrupt. It cannot return to run-time (non-DFU) operations
Clearing status
Determining device status...
DFU state(2) = dfuIDLE, status(0) = No error condition is present
DFU mode device DFU version 011a
Device returned transfer size 2048
DfuSe interface name: "Internal Flash  "
Downloading element to address = 0x08000000, size = 73668
Erase   	[                         ]   0%            0 bytesErase   	[                         ]   0%            0 bytesErase   	[                         ]   2%         2048 bytesErase   	[=                        ]   5%         4096 bytesErase   	[==                       ]   8%         6144 bytesErase   	[==                       ]  11%         8192 bytesErase   	[===                      ]  13%        10240 bytesErase   	[====                     ]  16%        12288 bytesErase   	[====                     ]  19%        14336 bytesErase   	[=====                    ]  22%        16384 bytesErase   	[======                   ]  25%        18432 bytesErase   	[=======                  ]  30%        22528 bytesErase   	[========                 ]  33%        24576 bytesErase   	[=========                ]  36%        26624 bytesErase   	[=========                ]  38%        28672 bytesErase   	[==========               ]  41%        30720 bytesErase   	[===========              ]  44%        32768 bytesErase   	[===========              ]  47%        34816 bytesErase   	[============             ]  50%        36864 bytesErase   	[=============            ]  52%        38912 bytesErase   	[=============            ]  55%        40960 bytesErase   	[==============           ]  58%        43008 bytesErase   	[===============          ]  61%        45056 bytesErase   	[===============          ]  63%        47104 bytesErase   	[================         ]  66%        49152 bytesErase   	[=================        ]  69%        51200 bytesErase   	[==================       ]  72%        53248 bytesErase   	[===================      ]  77%        57344 bytesErase   	[====================     ]  80%        59392 bytesErase   	[=====================    ]  86%        63488 bytesErase   	[======================   ]  88%        65536 bytesErase   	[======================   ]  91%        67584 bytesErase   	[=======================  ]  94%        69632 bytesErase   	[======================== ]  97%        71680 bytesErase   	[=========================] 100%        73668 bytes
Erase    done.
Download	[                         ]   0%            0 bytesDownload	[                         ]   2%         2048 bytesDownload	[=                        ]   5%         4096 bytesDownload	[==                       ]   8%         6144 bytesDownload	[==                       ]  11%         8192 bytesDownload	[===                      ]  13%        10240 bytesDownload	[====                     ]  16%        12288 bytesDownload	[====                     ]  19%        14336 bytesDownload	[=====                    ]  22%        16384 bytesDownload	[======                   ]  25%        18432 bytesDownload	[======                   ]  27%        20480 bytesDownload	[=======                  ]  30%        22528 bytesDownload	[========                 ]  33%        24576 bytesDownload	[=========                ]  36%        26624 bytesDownload	[=========                ]  38%        28672 bytesDownload	[==========               ]  41%        30720 bytesDownload	[===========              ]  44%        32768 bytesDownload	[===========              ]  47%        34816 bytesDownload	[============             ]  50%        36864 bytesDownload	[=============            ]  52%        38912 bytesDownload	[=============            ]  55%        40960 bytesDownload	[==============           ]  58%        43008 bytesDownload	[===============          ]  61%        45056 bytesDownload	[===============          ]  63%        47104 bytesDownload	[================         ]  66%        49152 bytesDownload	[=================        ]  69%        51200 bytesDownload	[==================       ]  72%        53248 bytesDownload	[==================       ]  75%        55296 bytesDownload	[===================      ]  77%        57344 bytesDownload	[====================     ]  80%        59392 bytesDownload	[====================     ]  83%        61440 bytesDownload	[=====================    ]  86%        63488 bytesDownload	[======================   ]  88%        65536 bytesDownload	[=======================  ]  94%        69632 bytesDownload	[======================== ]  97%        71680 bytesDownload	[=========================] 100%        73668 bytes
Download done.
File downloaded successfully
Submitting leave request...
Transitioning to dfuMANIFEST state
```

## 7단계 프로토콜 검증

### probe (R6)
```
node: /dev/hidraw5
protocol revision: 1
LED count: 89
LEDs per packet: 9
```

### enter + set 0 255 0 0 (AE1)
```
```

**AE1 관찰 결과: 충족.** 조작자 확인 — "ESC is red now". LED 인덱스 0이 호스트가 지정한 빨강으로 점등.

### frame 0 255 0 (R7)
```
```

비고 (표준출력 아님, 조작자 주석): 89개 LED / 패킷당 9개 = 10개 패킷 (9x9=81 + 8). `cmd_frame`은 `_write_only`를 거치며 성공 시 표준출력을 내지 않는다 — 위 빈 코드 블록이 실제로 캡처된 출력이다.

**R7 관찰 결과: 충족.** 조작자 확인 — "every key is green except logo and upper strip". 89개 키 LED 전체가 호스트 프레임으로 덮였고, 앞서 빨강이던 인덱스 0도 초록으로 갱신되었다.

로고와 상단 스트립이 영향받지 않은 것은 기대 동작이다. 그 12개(로고 7 + 사이드 5)는 별도 WS2812 체인이며 `keyboards/nuphy/gem80/config.h`가 `RGB_MATRIX_LED_COUNT 89 // sides 5 + 7, not included here`로 명시한다. KEYS 영역의 경계가 설계대로 그어져 있음이 실물로 확인되었다. SIDE 영역 제어는 프로토콜 확장이 필요한 별도 작업이다.

### exit (AE2)
```
```

비고 (표준출력 아님, 조작자 주석): `60 01 00` 페이로드 전송, exit code 0. `cmd_exit`도 `_write_only`를 거치며 표준출력이 없다 — 위 빈 코드 블록이 실제로 캡처된 출력이다.

**AE2 관찰 결과: 충족.** 조작자 확인 — "default effect works for usb connection". `60 01 00` 이후 EEPROM에 저장된 효과로 복귀. R6, R7, R8 모두 충족.

## 8단계 무선 확인 (R9)

### 블루투스

- 조건: USB 미열거 확인, `bluetoothctl devices Connected` -> `NuPhy Gem80#1`, 조작자가 기본 효과 동작 확인
- hidraw 노드: `hidraw4` 하나. 디스크립터의 usage는 키보드(0x0001/0x06), 키패드(0x0007/0x05), 컨슈머(0x000C/0x01), 포인터뿐
- 결과: **raw HID 엔드포인트(usage page 0xFF60, usage 0x61) 없음.** 종료 코드 2

`/dev/hidraw4`는 `crw-------`(root 전용, uaccess 없음)이지만 판정 근거는 권한이 아니다. 도구가 sysfs의 world-readable `report_descriptor`를 읽어 엔드포인트 부재를 확인했으므로 "권한 거부"가 아니라 "엔드포인트 없음"이다. 두 결과를 구분하지 않았다면 근거 없이 같은 결론에 도달했을 것이다.

### 2.4G 동글

- 조건: 키보드 USB 직결 없음 확인, 동글 `19f5:3247` 열거, 조작자가 동글 연결 확인
- 동글이 만드는 hidraw 노드 3개를 전수 확인:

| 노드 | usage page / usage | 내용 |
| --- | --- | --- |
| `hidraw5` | `0x0001/0x06` | 키보드 |
| `hidraw6` | `0x0001/*`, `0x000C/*` | 키보드 + 마우스 + 컨슈머 |
| `hidraw10` | `0xFF31/0x74`, `0x75`, `0x76` | 동글 자체 벤더 채널 |

- 결과: **QMK raw HID 엔드포인트(`0xFF60`/`0x61`) 없음.** 종료 코드 2

2.4G에 벤더 엔드포인트가 존재하기는 하나 `0xFF31`로, NuPhy 동글 고유 프로토콜이며 QMK의 raw HID가 아니다. 동글 펌웨어 업데이터가 쓰는 통로로 추정된다. 세 노드 모두 `crw-------`인 것은 `59-nuphy-gem80-via.rules`가 키보드(`3275`)만 매칭하고 동글(`3247`)은 매칭하지 않기 때문이며, 판정 근거는 권한이 아니라 sysfs 디스크립터 전수 확인이다.

**R9 결과: 충족 (음성).** 퍼키 direct 모드는 **USB 전용**이다. 블루투스에는 벤더 엔드포인트가 아예 없고, 2.4G에는 다른 벤더 페이지만 있다. 이슈 스레드의 예측 — RF가 UART로 붙은 별도 칩이라 raw HID가 닿지 않는다 — 이 두 경로 모두에서 확인되었다.

이 결과는 호스트 데몬 설계에 직접 반영되어야 한다. 사용자가 무선으로 전환하면 호스트 조명 제어가 완전히 불가능해지므로, 데몬은 그 상태를 감지하고 물러날 수 있어야 한다.

## 9단계 오버레이 관찰 (R10)

조건: 유선 복귀(`probe` -> `hidraw11`, LED 89 확인), direct 모드 진입 후 89개 전체를 파랑(`0 0 255`)으로 고정.

| 오버레이 | KEYS 영역 충돌 | 관찰 |
| --- | --- | --- |
| caps-lock 표시 | **없음** | 여러 번 토글해도 Caps Lock 키는 파랑 유지. 대신 **상단 스트립**이 변한다 — 표시가 별도 WS2812 체인에 렌더링된다 |
| 키 누름 하이라이트 | **없음** | direct 모드에서 하이라이트 효과가 나타나지 않는다 |
| 배터리 표시 | 미관찰 | `Fn`+`Del`은 무동작. 이 키맵에서 `BAT_SHOW`의 위치를 찾지 못했다 |
| 디바운스 값 표시 | **있음** | `Fn`+`Home`(`DEBOUNCE_PRESS_SHOW`)이 ESC와 숫자 키 하나를 초록으로, `Fn`+`End`(`DEBOUNCE_RELEASE_SHOW`)가 같은 자리를 빨강으로 덮는다. 숫자 키 위치는 현재 설정값을 나타낸다 |

**R10 결과: 충족 (충돌 1건 관찰).**

가장 중요한 발견은 caps-lock이 KEYS를 건드리지 않는다는 것이다. 계획과 이슈 스레드는 caps-lock 표시가 호스트와 같은 LED를 놓고 다툴 것을 우려했으나, 실제로는 사이드 체인에 그려진다. 키 누름 하이라이트도 direct 모드에서 비활성이다. 즉 상시 동작하는 오버레이 중 KEYS를 침범하는 것은 없다.

침범하는 것은 조작자가 명시적으로 누를 때만 뜨는 디바운스 표시다. 일시적이고 사용자가 유발하는 성격이라 상시 경합이 아니며, `keyboards/nuphy/gem80/ansi/keymaps/default/keymap.c`의 Fn 레이어에서 `Ins`/`Home`/`PgUp` = `DEBOUNCE_PRESS_*`, `Del`/`End`/`PgDn` = `DEBOUNCE_RELEASE_*`로 확인된다.

계획대로 이 충돌은 기록만 하고 고치지 않는다. 우선순위 정책은 후속 작업이다.

## 3차 플래시 (코드 리뷰 반영본)

- 일시: 2026-09-10T04:29:30Z
- 크기: 73688 bytes, sha256 964eed3f305427f1…
- 변경: `hostrgb_buf`를 fork의 packed `rgb_t`로 전환, direct 모드 진입 시 `rgb_matrix_enable_noeeprom()` 호출 (RGB_TOG로 꺼둔 상태에서도 켜지도록)
- 출처 게이트: `gem80-firmware verify` 통과 (종료 코드 0)

```
dfu-util 0.11

Copyright 2005-2009 Weston Schmidt, Harald Welte and OpenMoko Inc.
Copyright 2010-2021 Tormod Volden and Stefan Schmidt
This program is Free Software and has ABSOLUTELY NO WARRANTY
Please report bugs to http://sourceforge.net/p/dfu-util/tickets/

Opening DFU capable USB device...
Device ID 0483:df11
Device DFU version 011a
Claiming USB DFU Interface...
Setting Alternate Interface #0 ...
Determining device status...
DFU state(10) = dfuERROR, status(10) = Device's firmware is corrupt. It cannot return to run-time (non-DFU) operations
Clearing status
Determining device status...
DFU state(2) = dfuIDLE, status(0) = No error condition is present
DFU mode device DFU version 011a
Device returned transfer size 2048
DfuSe interface name: "Internal Flash  "
Downloading element to address = 0x08000000, size = 73672
Erase   	[                         ]   0%            0 bytesErase   	[                         ]   0%            0 bytesErase   	[                         ]   2%         2048 bytesErase   	[=                        ]   5%         4096 bytesErase   	[==                       ]   8%         6144 bytesErase   	[==                       ]  11%         8192 bytesErase   	[===                      ]  13%        10240 bytesErase   	[====                     ]  16%        12288 bytesErase   	[====                     ]  19%        14336 bytesErase   	[=====                    ]  22%        16384 bytesErase   	[======                   ]  25%        18432 bytesErase   	[======                   ]  27%        20480 bytesErase   	[=======                  ]  30%        22528 bytesErase   	[========                 ]  33%        24576 bytesErase   	[=========                ]  36%        26624 bytesErase   	[=========                ]  38%        28672 bytesErase   	[==========               ]  41%        30720 bytesErase   	[===========              ]  44%        32768 bytesErase   	[===========              ]  47%        34816 bytesErase   	[============             ]  50%        36864 bytesErase   	[=============            ]  52%        38912 bytesErase   	[==============           ]  58%        43008 bytesErase   	[===============          ]  61%        45056 bytesErase   	[===============          ]  63%        47104 bytesErase   	[================         ]  66%        49152 bytesErase   	[=================        ]  69%        51200 bytesErase   	[==================       ]  72%        53248 bytesErase   	[==================       ]  75%        55296 bytesErase   	[===================      ]  77%        57344 bytesErase   	[====================     ]  80%        59392 bytesErase   	[====================     ]  83%        61440 bytesErase   	[=====================    ]  86%        63488 bytesErase   	[======================   ]  88%        65536 bytesErase   	[======================   ]  91%        67584 bytesErase   	[=======================  ]  94%        69632 bytesErase   	[======================== ]  97%        71680 bytesErase   	[=========================] 100%        73672 bytes
Erase    done.
Download	[                         ]   0%            0 bytesDownload	[                         ]   2%         2048 bytesDownload	[=                        ]   5%         4096 bytesDownload	[==                       ]   8%         6144 bytesDownload	[==                       ]  11%         8192 bytesDownload	[===                      ]  13%        10240 bytesDownload	[====                     ]  16%        12288 bytesDownload	[====                     ]  19%        14336 bytesDownload	[=====                    ]  22%        16384 bytesDownload	[======                   ]  25%        18432 bytesDownload	[======                   ]  27%        20480 bytesDownload	[=======                  ]  30%        22528 bytesDownload	[========                 ]  33%        24576 bytesDownload	[=========                ]  36%        26624 bytesDownload	[=========                ]  38%        28672 bytesDownload	[==========               ]  41%        30720 bytesDownload	[===========              ]  44%        32768 bytesDownload	[===========              ]  47%        34816 bytesDownload	[============             ]  50%        36864 bytesDownload	[=============            ]  52%        38912 bytesDownload	[=============            ]  55%        40960 bytesDownload	[==============           ]  58%        43008 bytesDownload	[===============          ]  61%        45056 bytesDownload	[===============          ]  63%        47104 bytesDownload	[================         ]  66%        49152 bytesDownload	[=================        ]  69%        51200 bytesDownload	[==================       ]  72%        53248 bytesDownload	[==================       ]  75%        55296 bytesDownload	[===================      ]  77%        57344 bytesDownload	[====================     ]  80%        59392 bytesDownload	[====================     ]  83%        61440 bytesDownload	[=====================    ]  86%        63488 bytesDownload	[======================   ]  88%        65536 bytesDownload	[======================   ]  91%        67584 bytesDownload	[=======================  ]  94%        69632 bytesDownload	[======================== ]  97%        71680 bytesDownload	[=========================] 100%        73672 bytes
Download done.
File downloaded successfully
Submitting leave request...
Transitioning to dfuMANIFEST state
```

### 3차 플래시 후 검증

프로토콜 회귀 없음: `probe` -> 노드 `/dev/hidraw5`, 프로토콜 rev 1, LED 89, 패킷당 9, 종료 코드 0.

**`rgb_t` 전환의 채널 순서 보존: 확인.** `enter` 후 `set 0 255 0 0`을 보내자 조작자가 ESC의 빨강 점등을 확인했다. `hostrgb_buf`를 `uint8_t[3]`에서 fork의 packed `rgb_t`로 바꾼 변경이 메모리 레이아웃을 깨뜨리지 않았다는 뜻이다 — 어긋났다면 다른 색으로 나왔을 자리다.

**매트릭스 enable 수정: 양쪽 절반 모두 확인.** 이 키맵에는 `RGB_TOG`가 없어 전제 조건에 도달할 수 없었으나, 조작자가 VIA로 `RM_TOGG`를 추가해 검증이 가능해졌다.

| 단계 | 관찰 |
| --- | --- |
| `RM_TOGG`로 조명을 끔 | 키보드 깜깜 |
| `enter` + `frame 0 0 255` | **전체가 파랑으로 점등** — 수정 전이었다면 매트릭스가 꺼진 채라 쓰기만 승인되고 화면은 깜깜했을 것이다 |
| `exit` | **다시 깜깜해짐** — 저장된 "꺼짐"이 복원되었다 |

두 번째 행이 없으면 호스트는 "정상 동작"과 "아무것도 보이지 않음"을 종료 코드로 구분할 수 없다. 세 번째 행은 `enable_noeeprom` 변형을 고른 판단이 옳았음을 보인다: direct 모드가 조작자의 저장된 선호를 일시적으로만 덮고, 나가면서 되돌린다. 데몬이 물러난 뒤 사용자 설정이 조용히 바뀌지 않는다는 뜻이므로, 후속 데몬 작업이 이 성질에 기댈 수 있다.

에코 확인도 함께 실증되었다. 이번 빌드의 `enter`/`set`/`frame`/`exit`은 펌웨어 응답을 받은 뒤에 0을 반환하므로, 위 종료 코드들은 "바이트가 호스트를 떠났다"가 아니라 "장치가 명령을 처리했다"를 뜻한다.
