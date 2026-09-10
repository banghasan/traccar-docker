# Desain repository `banghasan/traccar-docker`

## 1. Tujuan dan batasan

Repository public `banghasan/traccar-docker` ini bukan fork penuh Traccar dan
bukan pengganti repository upstream. Isinya hanya definisi image, dokumentasi,
dan GitHub Actions untuk membangun image dari source upstream.

Dalam scope:

- memilih branch, tag, atau commit Traccar;
- build server dan web app;
- membuat image Docker Alpine untuk `linux/amd64`;
- publish image secara manual ke registry;
- dokumentasi koneksi ke database eksternal.

Di luar scope:

- menjalankan MySQL, MariaDB, PostgreSQL, atau TimescaleDB;
- menyediakan Docker Compose production lengkap;
- membuat installer Linux/Windows;
- otomatis mengikuti setiap commit upstream;
- memberi nama image seolah-olah image tersebut official Traccar.

## 2. Temuan dari repository upstream

Dockerfile upstream saat ini memiliki pola berikut:

```text
traccar-other-<VERSION>.zip (upstream) / traccar-other.zip (builder ini)
        │
        ├── server jar + lib
        ├── schema + templates + conf
        └── web app
                │
                ▼
      custom JRE via jlink
                │
                ▼
          /opt/traccar
```

Dockerfile tersebut menerima zip sebagai build context, mengekstraknya ke
`/opt/traccar`, membuat runtime Java minimal, lalu menjalankan:

```text
/opt/traccar/jre/bin/java -XX:+ExitOnOutOfMemoryError \
  -jar tracker-server.jar conf/traccar.xml
```

Workflow release upstream membangun server dengan `./gradlew assemble`, web app
dengan `npm ci && npm run build`, kemudian melakukan staging sebelum membuat
`traccar-other-<version>.zip`. Artinya, pendekatan paling kompatibel adalah
mempertahankan format payload tersebut dan hanya mengganti sumber versinya dari
release artifact menjadi hasil build source pilihan.

## 3. Pilihan strategi build

### Pilihan A — Dockerfile langsung clone dan compile source

Dockerfile melakukan `git clone`, compile Gradle, build web app, lalu membuat
runtime image.

Kekurangan:

- build Docker menjadi bergantung pada GitHub dan npm registry;
- sulit memisahkan kegagalan compile dari kegagalan image build;
- cache Docker dan build multi-platform menjadi lebih rumit;
- source commit yang digunakan kurang terlihat di metadata build.

### Pilihan B — GitHub Actions compile, Dockerfile hanya membuat runtime image

Workflow melakukan checkout dan compile, lalu mengirim payload hasil build ke
Docker Buildx. Dockerfile hanya mengemas payload menjadi runtime image.

Pilihan B direkomendasikan karena paling dekat dengan workflow release upstream,
lebih mudah diaudit, dan tetap menjaga repository baru tetap kecil. Payload harus
dibuat dari commit yang diketahui, lalu workflow menyimpan `source_ref` dan
`source_revision` pada label OCI image.

## 4. Input workflow manual

Workflow yang digunakan memiliki input:

| Input | Wajib | Nilai contoh | Keterangan |
|---|---:|---|---|
| `source_ref` | ya | `master` atau `5eb9578...` | Ref upstream yang di-checkout |
| `image_tag` | ya | `auto` atau `6.15.3-custom` | Tag image hasil build |

Default `source_ref` boleh `master` agar nyaman untuk bugfix terbaru, tetapi
deployment production harus memakai commit SHA atau tag internal immutable.

`image_tag` default ke `auto`. Setelah source di-checkout, workflow membaca
`Implementation-Version` dari `build.gradle` dan 7 karakter awal source SHA,
lalu menghasilkan tag `VERSION-dev.SHORT_SHA`, misalnya
`6.15.3-dev.5eb9578`. User tetap dapat mengganti `auto` dengan tag manual.

Nilai `auto` dihitung setelah workflow dimulai sehingga form GitHub menampilkan
teks `auto`, bukan versi final. Tag final dicatat pada build summary dan dipakai
oleh smoke test, preflight registry, serta publish. Alias seperti `latest` tetap
harus menjadi keputusan eksplisit pada workflow manual.

## 5. Langkah workflow yang diharapkan

Workflow final mengikuti urutan ini:

```text
workflow_dispatch
      │
      ▼
checkout traccar @ source_ref + submodule web (tanpa credential tersimpan)
      │
      ├── resolve image_tag (auto → VERSION-dev.SHORT_SHA)
      ├── setup Java 25 + Gradle cache
      ├── ./gradlew build
      ├── setup Node 22 + npm cache
      └── npm ci && npm run build pada traccar-web
      │
      ▼
stage server, lib, schema, templates, conf, web
      │
      ▼
buat traccar-other.zip
      │
      ▼
upload payload artifact
      │
      ▼
build image lokal + smoke test /api/health
      │
      ▼
Buildx: linux/amd64 + SBOM/provenance + attestation
      │
      ▼
push ke ghcr.io/banghasan/traccar
```

Workflow tidak boleh memiliki `push:` atau `schedule:` pada blok `on`. Permission
ditetapkan per job: job build dan smoke test hanya memiliki `contents: read`,
sedangkan job publish memiliki `contents: read`, `packages: write`,
`attestations: write`, dan `id-token: write` untuk attestation image.

Action pihak ketiga dipin ke commit SHA dengan komentar versi major agar
pembaruan dapat dilakukan secara terkontrol.

## 6. Registry dan penamaan image

Registry yang digunakan adalah GHCR karena terintegrasi dengan GitHub Actions.
Image name final:

```text
ghcr.io/banghasan/traccar
```

Contoh penamaan:

```text
ghcr.io/banghasan/traccar:6.15.3-dev.5eb9578
ghcr.io/banghasan/traccar:sha-5eb9578
```

Label OCI yang disarankan:

- `org.opencontainers.image.source` — URL repository builder;
- `org.opencontainers.image.revision` — commit source Traccar;
- `org.opencontainers.image.version` — `image_tag`;
- `org.opencontainers.image.created` — waktu build.

Tag utama sebaiknya immutability-friendly. Workflow menolak tag yang sudah ada,
tetapi digest tetap harus disimpan dan digunakan pada deployment yang membutuhkan
repeatability.

## 7. Konfigurasi database eksternal

Image tetap membawa driver database yang sudah tersedia pada server
Traccar, tetapi tidak membawa service database. Saat container dijalankan,
environment variable berikut dapat diteruskan ke konfigurasi Traccar:

```text
CONFIG_USE_ENVIRONMENT_VARIABLES=true
DATABASE_DRIVER=com.mysql.cj.jdbc.Driver
DATABASE_URL=jdbc:mysql://mysql:3306/traccar?...
DATABASE_USER=traccar
DATABASE_PASSWORD=<secret>
```

Untuk PostgreSQL/TimescaleDB, ganti driver dan JDBC URL sesuai dokumentasi
Traccar. Password tidak boleh ditulis di repository atau command history pada
server production; gunakan secret manager atau mekanisme secret Docker.

Sample Compose tersedia di
[`examples/docker-compose.external-mysql.yml`](../examples/docker-compose.external-mysql.yml).
Sample tersebut sengaja hanya mendefinisikan service Traccar dan memakai Docker
network eksternal; MySQL tetap dikelola di luar repository ini.

Contoh hanya mempublish port `5000` sebagai ilustrasi. Tambahkan pasangan port
TCP/UDP sesuai protocol yang digunakan; jangan mempublish seluruh rentang jika
tidak diperlukan.

Volume yang umumnya perlu dipertimbangkan:

- `/opt/traccar/logs` untuk log;
- `/opt/traccar/data` hanya bila konfigurasi memakai data lokal/H2 atau ada file
  runtime yang memang perlu dipertahankan;
- `/opt/traccar/conf/traccar.xml` jika memakai file konfigurasi sendiri.

## 8. Validasi dan rollback

Sebelum tag dipromosikan ke production:

1. Catat source SHA, image digest, dan hasil attestation.
2. Jalankan image pada database staging hasil restore backup.
3. Tunggu health endpoint `http://localhost:8082/api/health` merespons sukses.
4. Verifikasi web UI, login, migration, event, notification, dan protocol utama.
5. Uji restart container, koneksi ulang ke database, dan permission volume.
6. Promosikan hanya tag/digest yang lulus pengujian.

Rollback dilakukan dengan mengembalikan deployment ke digest image sebelumnya,
bukan dengan mengandalkan tag mutable.

## 9. Risiko yang harus diterima

- `master` dapat berisi perubahan yang belum stabil atau tidak kompatibel dengan
  data production.
- Build source bukan release resmi dan tidak otomatis memiliki support atau
  jaminan yang sama dengan image `traccar/traccar`.
- Dependency Gradle dan npm dapat berubah jika lockfile/ref tidak cocok; karena
  itu source commit dan artefak build perlu dicatat.
- Perbedaan versi server dan web app harus dihindari. Web app sebaiknya diambil
  dari submodule commit yang terkait dengan source server.
- Metadata versi di dalam aplikasi dapat masih mengikuti versi terakhir yang
  ditulis upstream pada source. Identitas build yang utama harus berupa image
  tag dan source commit OCI label.
- Target awal hanya `linux/amd64`; dukungan arsitektur lain dapat ditambahkan
  setelah validasi.

## 10. Implementasi saat ini dan tahap berikutnya

Implementasi awal yang sudah ditambahkan:

1. `Dockerfile.alpine` untuk image Alpine `linux/amd64`, base digest terkunci,
   healthcheck satu jam, init permission volume, dan proses Traccar non-root.
2. `.github/workflows/build-image.yml` dengan `workflow_dispatch` saja.
3. Build server, test, dan web app dari source upstream.
4. Smoke test sebelum publish, lalu publish ke
   `ghcr.io/banghasan/traccar` dengan job dan permission terpisah.
5. Payload reproducible, Docker cache, SBOM, provenance, dan attestation image.
6. `.dockerignore`, `.gitignore`, Dependabot, dan sample Compose tanpa service
   MySQL.

Tahap berikutnya:

1. Jalankan satu build manual ke tag sementara.
2. Uji dengan database staging eksternal.
3. Dokumentasikan digest image yang lulus validasi.
