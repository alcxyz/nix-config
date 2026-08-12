{runCommandCC}:
runCommandCC "kdeconnect-scroll-throttle" {} ''
  install -d "$out/lib"
  "$CC" \
    -shared \
    -fPIC \
    -Wall \
    -Wextra \
    -Werror \
    -nodefaultlibs \
    -Wl,--allow-shlib-undefined \
    -o "$out/lib/libkdeconnect-scroll-throttle.so" \
    ${./kdeconnect-scroll-throttle.c}
''
