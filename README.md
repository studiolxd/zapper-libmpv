# zapper-libmpv

mpv and FFmpeg built as **one dynamic framework** (`Libmpv.framework`, iOS, iOS Simulator and macOS) for the
[Zapper IPTV](https://zapperiptv.app) app, under **LGPL-3.0-or-later** with no GPL or non-free component. This repository
is the corresponding source offer required by the LGPL: the build script, the exact pinned sources (`sources.lock`)
and, in each [release](../../releases), the prebuilt `Libmpv.xcframework.zip` plus `libmpv-lgpl-sources.tar.gz` with
the complete source of every component. Anyone can rebuild the framework with `./build.sh` and replace the one inside
the app.

Licence texts: `COPYING.LESSER` (LGPL-3.0) and `COPYING` (GPL-3.0, which the LGPL refers to). Component licences are
listed below.

---

# Libmpv — mpv y FFmpeg enlazados de forma dinámica (LGPL)

La app de Apple usa mpv (con FFmpeg debajo) para lo que AVPlayer no abre: MKV, AVI y TS crudo
(`docs/APPLE.md` §4). Hasta octubre de 2026 venía de [MPVKit](https://github.com/mpvkit/MPVKit), cuyos
binarios son **estáticos**; con la LGPL eso obliga a entregar los objetos para volver a enlazar la
app, algo que no casa con la App Store. Este paquete sustituye a MPVKit por **un único framework
dinámico**, `Libmpv.framework`, que la app embebe y firma (`Frameworks/` en iOS,
`Contents/Frameworks/` en el Mac) y que cualquiera puede recompilar y cambiar por el suyo.

El módulo se sigue llamando `Libmpv`, como en MPVKit, así que el código (`import Libmpv`) no cambia.

## Qué hay dentro

Una sola biblioteca dinámica por plataforma con mpv, FFmpeg y sus dependencias, que **solo exporta la
API de libmpv** (`mpv_*`, ver `exports.txt`). Ninguna parte es GPL ni «nonfree»:

| Componente | Versión | Licencia | Cómo llega |
|---|---|---|---|
| mpv | v0.41.0 | LGPL-2.1-or-later (`-Dgpl=false`) | Compilado aquí |
| FFmpeg | n8.0.1 | LGPL-3.0-or-later (`--enable-version3`, sin `--enable-gpl` ni `--enable-nonfree`) | Compilado aquí |
| GnuTLS | 3.8.11 | LGPL-2.1-or-later | Estático de mpvkit/gnutls-build |
| Nettle / Hogweed | 3.10 | LGPL-3.0-or-later o GPL-2.0-or-later (se usa la LGPL) | Ídem |
| GMP | 6.2.1 | LGPL-3.0-or-later o GPL-2.0-or-later (se usa la LGPL) | Ídem |
| libass | 0.17.4 | ISC | mpvkit/libass-build |
| FriBidi | 1.0.12 | LGPL-2.1-or-later | Ídem |
| FreeType | 2.12.1 | FreeType License (FTL) | Ídem |
| HarfBuzz | 8.1.1 | MIT («Old MIT») | Ídem |
| libunibreak | 6.1 | zlib | Ídem |
| libplacebo | 7.351.0 | LGPL-2.1-or-later | mpvkit/libplacebo-build |
| Little CMS | 2.17 | MIT | mpvkit/lcms2-build |
| libdovi | 3.3.2 | MIT | mpvkit/libdovi-build |
| MoltenVK | 1.4.1 | Apache-2.0 | mpvkit/moltenvk-build |
| shaderc (con glslang y SPIRV-Tools) | 2025.5.0 | Apache-2.0 (glslang: BSD-3/MIT) | mpvkit/libshaderc-build |
| dav1d | 1.5.2 | BSD-2-Clause | mpvkit/libdav1d-build |
| uavs3d | 1.2.1 | BSD-3-Clause | mpvkit/libuavs3d-build |
| uchardet | 0.0.8 | MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later (se usa la LGPL) | mpvkit/libuchardet-build |
| LuaJIT (solo macOS) | 2.1.0 | MIT | mpvkit/libluajit-build |

Fuera respecto a MPVKit: **libsmbclient** (GPL-3, solo en MPVKit-GPL) y **libbluray** (discos Blu-ray,
inútil aquí). MPVKit también descarga OpenSSL, pero FFmpeg usa GnuTLS y `build.sh` no lo enlaza. Las versiones exactas, con el commit de cada etiqueta, están en `sources.lock`.

El conjunto se distribuye como LGPL-3.0-or-later (la versión 3 la imponen GMP, Nettle y FFmpeg con
`--enable-version3`); el resto de licencias son compatibles y sus avisos van en el paquete de fuentes.

## Cómo se compila

```sh
cd apple/Vendor/Libmpv
./build.sh            # fetch + mpvkit + link: unos 40 min en un M4 la primera vez
./build.sh sources    # paquete con la fuente correspondiente (dist/libmpv-lgpl-sources.tar.gz)
```

Requisitos: Xcode 26 o posterior y Homebrew con `meson ninja nasm cmake pkg-config wget`
(`brew install meson ninja nasm cmake pkg-config wget`). El directorio de trabajo es
`~/Library/Caches/zapper-libmpv` (variable `WORK_DIR`), fuera del repo.

Lo que hace `build.sh`:

1. **fetch** — clona MPVKit en la etiqueta `0.41.0` (comprueba el commit
   `613c0ccc3acf70e136aaff880a9b5fe8fdfaf5b8`) y le aplica dos cambios a
   `Sources/BuildScripts/XCFrameworkBuild/main.swift`:
   - quita `--enable-nonfree` de FFmpeg. MPVKit lo pasa incluso en su variante «LGPL» y convierte la
     compilación en *nonfree and unredistributable* (lo dice `avutil_license()` en sus binarios
     0.41.0);
   - no descarga libsmbclient ni libbluray.
2. **mpvkit** — `make build platform=ios,macos` sin `enable-gpl`: compila FFmpeg (configure) y mpv
   (meson, `-Dgpl=false`) como archivos estáticos para iOS arm64, simulador arm64 + x86_64 y macOS
   arm64 + x86_64, y descarga las dependencias ya compiladas de los repositorios `mpvkit/*-build`.
   Al terminar comprueba que **todos** los `libavutil.a` declaran `LGPL version 3 or later` y aborta
   si no.
3. **link** — por plataforma y arquitectura, enlaza `libmpv.a` (entero, `-force_load`) con el resto de
   archivos en una biblioteca dinámica (`-dynamiclib`, `-dead_strip`, solo exporta `mpv_*`), la junta
   con `lipo`, monta `Libmpv.framework` (con cabeceras y `module.modulemap`; versionado en el Mac) y
   crea `Libmpv.xcframework`, su zip y la suma de SwiftPM en `dist/`.
4. **sources** — junta MPVKit con el parche, los árboles de FFmpeg y mpv que se compilaron (con los
   parches de MPVKit aplicados) y cada componente de `sources.lock` clonado en su etiqueta
   (submódulos incluidos), y aborta si alguna etiqueta ya no apunta al commit fijado.

Las opciones de configuración completas de FFmpeg y mpv son las de `BuildFFMPEG.arguments` y
`BuildMPV.arguments` en el `main.swift` de MPVKit, con los cambios anteriores. La de mpv se puede
leer en el binario (`strings Libmpv.framework/Libmpv | grep -- -Dgpl=`); la de FFmpeg está en el
`pkgconfig` y en `libavutil.a` de `WORK_DIR/MPVKit/dist/FFmpeg`, porque el enlace con `-dead_strip`
la quita del framework.

## Cómo cambiarlo por uno propio (LGPL)

La app carga `Libmpv.framework` en tiempo de ejecución mediante `@rpath` y solo usa la API pública de
libmpv, así que vale cualquier `Libmpv.framework` compatible con esa interfaz:

1. Modificar mpv, FFmpeg o cualquier dependencia en el paquete de fuentes (o en `WORK_DIR`) y volver a
   ejecutar `./build.sh mpvkit` y `./build.sh link`.
2. **Con el proyecto:** copiar `Libmpv.xcframework` en este directorio y compilar la app con Xcode.
3. **Sobre una app ya instalada en el Mac:** sustituir `Zapper IPTV.app/Contents/Frameworks/Libmpv.framework`
   y volver a firmar (`codesign --force --deep --sign - "Zapper IPTV.app"` para uso local). En iOS el sistema
   exige firmar la app con un certificado propio para instalarla, como con cualquier app.

## Dónde viven los binarios

`Libmpv.xcframework` (146 MB; 62 MB el zip) no se versiona en git: es grande y aquí no hay LFS.
En la app pesa unos 28 MB en iPhone (arm64) y 65 MB en el Mac (universal).
Hoy `Package.swift` apunta a la copia local (`path:`), que se obtiene con `./build.sh`. Para no tener
que compilarla en cada máquina, el último `link` deja una copia del zip en
`~/Library/Caches/zapper-libmpv/` (basta descomprimirla aquí), y el plan es publicar `dist/Libmpv.xcframework.zip` y
`dist/libmpv-lgpl-sources.tar.gz` como recursos de una *release* pública y pasar a
`.binaryTarget(name: "Libmpv", url: …, checksum: …)` con la suma de `dist/Libmpv.xcframework.checksum`.
Esa misma página pública es la que cumple la obligación de ofrecer la fuente: el repositorio de la app
es privado y no sirve para eso.
