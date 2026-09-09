# Desain repository `banghasan/traccar-docker`

## 1. Tujuan dan batasan

Repository public ini bukan fork penuh Traccar dan bukan pengganti repository
upstream. Isinya hanya definisi image, dokumentasi, dan GitHub Actions untuk
membangun image dari source upstream.

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
traccar-other-<VERSION>.zip
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

Workflow yang akan dibuat pada tahap implementasi sebaiknya memiliki input:

| Input | Wajib | Nilai contoh | Keterangan |
|---|---:|---|---|
| `source_ref` | ya | `master` atau `5eb9578...` | Ref upstream yang di-checkout |
| `image_tag` | ya | `6.15.3-master.20260909` | Tag image hasil build |
Default `source_ref` boleh `master` agar nyaman untuk bugfix terbaru, tetapi
deployment production harus memakai commit SHA atau tag internal immutable.

`image_tag` tidak boleh otomatis memakai `latest` untuk source yang berubah.
Jika alias seperti `latest` atau `edge` memang diperlukan, publish alias itu
harus menjadi keputusan eksplisit pada workflow manual.

## 5. Langkah workflow yang diharapkan

Workflow final akan mengikuti urutan ini:

```text
workflow_dispatch
      │
      ▼
checkout traccar @ source_ref + submodule web
      │
      ├── setup Java 25 + Gradle cache
      ├── ./gradlew assemble
      ├── setup Node 22 + npm cache
      └── npm ci && npm run build pada traccar-web
      │
      ▼
stage server, lib, schema, templates, conf, web
      │
      ▼
buat traccar-other-<version>.zip
      │
      ▼
Buildx: linux/amd64
      │
      ▼
push ke ghcr.io/banghasan/traccar
```

Workflow tidak boleh memiliki `push:` atau `schedule:` pada blok `on`. Karena
workflow selalu melakukan publish setelah build manual, permission minimumnya
adalah `contents: read` dan `packages: write`.

Action pihak ketiga sebaiknya menggunakan versi major yang dipelihara dan,
untuk repository production yang memerlukan supply-chain control ketat, dipin ke
commit SHA.

## 6. Registry dan penamaan image

Registry yang digunakan adalah GHCR karena terintegrasi dengan GitHub Actions.
Image name final:

```text
ghcr.io/banghasan/traccar
```

Contoh penamaan:

```text
ghcr.io/banghasan/traccar:6.15.3-master.20260909
ghcr.io/banghasan/traccar:sha-5eb9578
```

Label OCI yang disarankan:

- `org.opencontainers.image.source` — URL repository builder;
- `org.opencontainers.image.revision` — commit source Traccar;
- `org.opencontainers.image.version` — `image_tag`;
- `org.opencontainers.image.created` — waktu build.

Tag utama sebaiknya immutability-friendly. Simpan digest hasil publish dan
gunakan digest tersebut pada deployment yang membutuhkan repeatability.

## 7. Konfigurasi database eksternal

Image harus tetap membawa driver database yang sudah tersedia pada server
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

Volume yang umumnya perlu dipertimbangkan:

- `/opt/traccar/logs` untuk log;
- `/opt/traccar/data` hanya bila konfigurasi memakai data lokal/H2 atau ada file
  runtime yang memang perlu dipertahankan;
- `/opt/traccar/conf/traccar.xml` jika memakai file konfigurasi sendiri.

## 8. Validasi dan rollback

Sebelum tag dipromosikan ke production:

1. Catat source SHA dan image digest.
2. Jalankan image pada database staging hasil restore backup.
3. Tunggu health endpoint `http://localhost:8082/api/health` merespons sukses.
4. Verifikasi web UI, login, migration, event, notification, dan protocol utama.
5. Uji restart container dan koneksi ulang ke database.
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
- Target awal hanya `linux/amd64`; dukungan arsitektur lain dapat ditambahkan
  setelah validasi.

## 10. Tahap implementasi berikutnya

Setelah rancangan disetujui:

1. Tambahkan `Dockerfile.alpine` yang diadaptasi minimal dari upstream.
2. Tambahkan `.github/workflows/build-image.yml` dengan `workflow_dispatch` saja.
3. Tambahkan konfigurasi registry dan permission minimum.
4. Jalankan satu build manual ke tag sementara.
5. Uji dengan database staging eksternal.
6. Dokumentasikan digest dan prosedur rollback.

Tahap tersebut sengaja belum dilakukan pada saat dokumentasi ini dibuat.
