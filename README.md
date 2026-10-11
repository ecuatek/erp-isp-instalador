# Instalador del ERP-ISP

Una sola instruccion sobre **Ubuntu 24.04 recien instalado**, con el
dominio ya apuntando a la maquina:

```bash
curl -fsSL https://raw.githubusercontent.com/ecuatek/erp-isp-instalador/main/instalar.sh \
  | sudo APP_DOMAIN=<dominio> ADMIN_EMAIL=<correo> bash
```

Si este repositorio es **privado**, la instruccion lleva un token de
lectura, y **dos veces**: la primera la usa el `curl` para traer este
guion, la segunda es la que el guion necesita para traer los otros dos.

```bash
curl -fsSL -H "Authorization: token <TOKEN>" \
  https://raw.githubusercontent.com/ecuatek/erp-isp-instalador/main/instalar.sh \
  | sudo INSTALADOR_TOKEN=<TOKEN> APP_DOMAIN=<dominio> ADMIN_EMAIL=<correo> bash
```

Instala y deja funcionando PHP, PostgreSQL, Redis, nginx, Node,
FreeRADIUS y Docker; despliega el ERP, emite el certificado y crea el
primer administrador.

**Se detiene una vez**, para que alguien con acceso al repositorio
autorice la maquina: imprime una llave de despliegue y dice que hacer con
ella. Se vuelve a ejecutar la misma instruccion y continua desde ahi.

## Variables

| Variable | Para que | Por omision |
|---|---|---|
| `APP_DOMAIN` | Por donde se entra al ERP | — (obligatoria) |
| `ADMIN_EMAIL` | Primer administrador y aviso del certificado | sin ella no crea usuario ni emite certificado |
| `PUERTO_PUBLICO` | El puerto por el que se entra, si hay un NAT delante | `443` |

`PUERTO_PUBLICO` **tiene que ser correcto antes de instalar**: viaja
dentro del JavaScript que se compila, asi que cambiarlo despues obliga a
recompilar.

## Lo que queda despues

Se hace desde el ERP, porque son datos que solo tiene el ISP: la ficha de
la empresa, la marca, el Telegram de las alertas y los equipos NAS.

Y una sola cosa por SSH, porque depende de las IP de los BRAS:

```bash
sudo ufw allow from <ip-del-bras> to any port 1812,1813 proto udp
```

## Como esta la maquina

```bash
sudo -u erpisp php8.3 /var/www/erp-isp/artisan sistema:revisar
```

---

Publicado desde el repositorio del ERP. No se edita aqui: los cambios se
pierden en la siguiente version.
