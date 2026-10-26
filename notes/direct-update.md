

AVNS_Dx-xITNqpAxVAsAF6gm

```
pg_restore \
  --no-owner --no-privileges \
  --dbname="$DATABASE_URL" \
  --exit-on-error \
  ./db/fa.dump

```

```
  ADMIN_URI=$(doctl databases connection "$DB_ID" --format URI --no-header)
```






│ postgresql://:********@future-advisor-pg-do-user-47176686-0.h.db.ondigitalocean.com:25060/defaultdb?sslmode=require │



export PGUSER=doadmin
export PGPASSWORD='AVNS_Dx-xITNqpAxVAsAF6gm'
export PGHOST=fa-pg-do-user-47176686-0.b.db.ondigitalocean.com
export PGPORT=25060
export PGDATABASE=future_advisor
export PGSSLMODE=require
export ADMIN_URI_FA=postgresql://doadmin:AVNS_Dx-xITNqpAxVAsAF6gm@future-advisor-pg-do-user-47176686-0.h.db.ondigitalocean.com:25060/future_advisor?sslmode=require


pg_restore --no-owner --no-privileges \
           --dbname="$DATABASE_URL" \
           --exit-on-error ./db/fa.dump


psql "$ADMIN_URI_FA" <<'SQL'
DROP SCHEMA IF EXISTS gold CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public AUTHORIZATION fa;
CREATE SCHEMA gold   AUTHORIZATION fa;
GRANT ALL ON SCHEMA public TO fa;
GRANT ALL ON SCHEMA gold   TO fa;
SQL


read -s -p "New admin password: " NEW_PW; echo
read -s -p "New admin password: " NEW_PW; echo
read -p "New admin email (blank = keep admintesting@local): " NEW_EMAIL
NEW_EMAIL=${NEW_EMAIL:-admin@local}



INSERT INTO public."user" (id, email, name, role, "passwordHash", "isActive", "createdAt")
VALUES (gen_random_uuid(), 'your.name@example.com', 'Your Name', 'admin',
        '$HASH', true, now());

username: admintesting@local
password: vkMnYQGbFMctYjPy5UYk