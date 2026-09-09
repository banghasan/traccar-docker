# banghasan/traccar-docker

Repository terpisah untuk membangun Docker image Traccar dari source
code upstream, termasuk commit di `master` yang belum masuk release resmi.

Repository ini hanya menangani proses build dan publish image. Database tidak
dimasukkan ke dalam image; MySQL/MariaDB atau PostgreSQL/TimescaleDB dijalankan
sebagai service terpisah.

> Status: implementasi awal tersedia. Docker build dan publish image belum
> dijalankan dari workspace ini.

## Keputusan rancangan

Rancangan ini layak digunakan dengan ketentuan berikut:

- Repository ini bersifat public dan image dipublish ke
  `ghcr.io/banghasan/traccar`.
- Source Traccar diambil dari `traccar/traccar` pada `source_ref` yang dipilih
  ketika workflow dijalankan.
- `source_ref` sebaiknya berupa commit SHA untuk build yang reproducible. Branch
  seperti `master` tetap dapat dipakai untuk mengambil perbaikan terbaru.
- Workflow hanya memiliki trigger `workflow_dispatch`; tidak ada build otomatis
  pada `push`, `pull_request`, atau jadwal. Setiap run yang berhasil langsung
  melakukan push ke GHCR.
- Build menjalankan server Gradle dan web app, kemudian membuat payload yang
  setara dengan `traccar-other-<version>.zip` milik upstream.
- Dockerfile runtime mengikuti pola resmi Traccar: custom JRE dibuat dengan
  `jlink`, lalu aplikasi dijalankan dari `/opt/traccar`.
- Image hanya ditargetkan untuk `linux/amd64` pada tahap awal.
- Image diberi tag yang mengidentifikasi source ref/commit. Tag `latest` tidak
  boleh dipindahkan diam-diam ke source yang berbeda.

## Mengapa perlu repository ini?

Dockerfile resmi di folder [`docker/`](https://github.com/traccar/traccar/tree/master/docker)
tidak melakukan compile source. Dockerfile tersebut menyalin dan mengekstrak
`traccar-other-$VERSION.zip`, yaitu artefak dari proses release. Akibatnya,
mengubah tag Docker saja tidak akan membuat image berisi commit terbaru di
`master`.

Build source server resmi menggunakan `./gradlew assemble`. Proses release juga
membangun web app dari repository `traccar-web`, menggabungkan server, web,
schema, template, konfigurasi, dan runtime Java ke dalam payload zip. Repository
baru ini akan mengambil bagian build tersebut tanpa membuat installer OS atau
menjalankan database.

## Struktur repository

```text
.
├── .github/
│   └── workflows/
│       └── build-image.yml       # manual workflow_dispatch + push GHCR
├── docs/
│   └── REPOSITORY-DESIGN.md      # keputusan dan prosedur operasional
├── Dockerfile.alpine             # image Alpine, linux/amd64
├── .dockerignore
├── .gitignore
└── README.md
```

Tahap pertama hanya menyediakan image Alpine `linux/amd64`. Variant Debian,
Ubuntu, atau arsitektur lain dapat ditambahkan setelah image utama tervalidasi.

## Cara menjalankan hasil image

Contoh berikut memakai MySQL yang sudah tersedia di jaringan Docker bernama
`backend`:

```bash
docker run -d \
  --name traccar \
  --restart unless-stopped \
  --network backend \
  -p 8082:8082 \
  -p 5000-5500:5000-5500 \
  -e CONFIG_USE_ENVIRONMENT_VARIABLES=true \
  -e DATABASE_DRIVER=com.mysql.cj.jdbc.Driver \
  -e "DATABASE_URL=jdbc:mysql://mysql:3306/traccar?zeroDateTimeBehavior=round&serverTimezone=UTC&allowPublicKeyRetrieval=true&useSSL=false&allowMultiQueries=true&autoReconnect=true&useUnicode=yes&characterEncoding=UTF-8&sessionVariables=sql_mode=''" \
  -e DATABASE_USER=traccar \
  -e DATABASE_PASSWORD='ganti-password' \
  -v /opt/traccar/logs:/opt/traccar/logs \
  -v /opt/traccar/data:/opt/traccar/data \
  ghcr.io/banghasan/traccar:<image-tag>
```

Nama host `mysql`, credential, volume, dan network hanyalah contoh. Image
builder tidak membuat container MySQL dan tidak mengelola migrasi database
secara terpisah; Traccar tetap menjalankan mekanisme database-nya saat start.

Untuk deployment production, gunakan database eksternal yang persistent dan
backup database secara terpisah. Port protocol tidak perlu dipublish seluruhnya
jika hanya sebagian protocol yang digunakan.

## Alur build

1. User membuka **Actions → Build Traccar Image → Run workflow**.
2. User mengisi `source_ref`, misalnya commit SHA, tag, atau `master`.
3. GitHub Actions checkout source Traccar beserta submodule `traccar-web`.
4. Runner memasang Java dan Node.js, lalu menjalankan server build dan web build.
5. Workflow men-stage `tracker-server.jar`, dependency `lib`, `schema`,
   `templates`, konfigurasi, dan hasil web build.
6. Payload dikemas sebagai `traccar-other-<version>.zip`.
7. Docker Buildx membangun image untuk `linux/amd64`.
8. Setelah build berhasil, image dipush ke `ghcr.io/banghasan/traccar`.

Input workflow yang tersedia:

- `source_ref`: branch, tag, atau commit SHA upstream; default `master`.
- `image_tag`: tag Docker yang akan dipublish, misalnya
  `6.15.3-dev.5eb9578`.

Workflow selalu melakukan push setelah build berhasil. Tidak ada mode build-only
pada workflow ini.

Perlu diperhatikan bahwa versi yang ditampilkan oleh server Traccar dapat masih
mengikuti metadata versi di source upstream. Untuk membedakan build source
terbaru, gunakan `image_tag` dan label commit image sebagai sumber identitas
utama.

## Verifikasi sebelum dipakai production

- Pastikan tag image mencatat commit source yang benar.
- Jalankan container dengan database staging eksternal.
- Periksa `/api/health`, login web, koneksi database, migration, dan satu atau
  dua protocol GPS yang digunakan.
- Uji upgrade dari image lama dengan volume data dan konfigurasi yang sama.
- Simpan digest image yang sudah diuji; gunakan digest atau tag immutable untuk
  deployment production.

Package GHCR harus diubah menjadi public jika GitHub membuatnya private pada
publish pertama. Repository source ini sendiri bersifat public.

## Referensi

- [Traccar Dockerfiles upstream](https://github.com/traccar/traccar/tree/master/docker)
- [Dockerfile Alpine upstream](https://github.com/traccar/traccar/blob/master/docker/Dockerfile.alpine)
- [Workflow release upstream](https://github.com/traccar/traccar/blob/master/.github/workflows/release.yml)
- [Panduan build dari source](https://www.traccar.org/build/)
- [Panduan Docker resmi Traccar](https://www.traccar.org/docker/)
- [Contoh Compose Traccar + MySQL](https://github.com/traccar/traccar/blob/master/docker/compose/traccar-mysql.yaml)
