# Third-Party Notices

이 프로젝트 전체는 [MIT 라이선스](LICENSE)를 따릅니다. 아래 프로젝트에서 가져온 부분에는 각 프로젝트의 MIT 라이선스가 함께 적용되며, 그 저작권 고지와 허가 문구를 여기에 그대로 둡니다.

## HangulSync

- 사용한 부분: 입력 소스 조회와 대체(fallback) 규칙, 에코 억제 방식, 뷰어 앱 번들 ID 접두사 목록, 세션 신호 유효시간·재전송 주기, TCP 전송 튜닝
- 저장소: https://github.com/catgarret/HangulSync

```
MIT License

Copyright (c) 2026 dongri.me

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## DeskPad

- 사용한 부분: `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` 비공개 클래스의 선언(속성·메서드 이름)과 가상 디스플레이를 만드는 호출 순서. 이 앱은 헤더를 가져오지 않고 런타임에 클래스와 셀렉터를 찾아 쓴다.
- 저장소: https://github.com/Stengo/DeskPad

```
MIT License

Copyright (c) 2022 Bastian Andelefski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
