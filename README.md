# postgres_dba (PostgresDBA)
The missing set of useful tools for Postgres DBA and mere mortals.

:warning: If you have great ideas, feel free to create a pull request or open an issue.

<img alt="Demo" src="https://user-images.githubusercontent.com/1345402/74124060-dbe25c00-4b85-11ea-9538-8d3b67f09896.gif">


:point_right: See also [postgres_ai](https://github.com/postgres-ai/postgres_ai), a comprehensive monitoring and optimization platform that includes automated health checks, SQL performance analysis, and much more.

## Questions?

Questions? Ideas? Contact me: nik@postgres.ai, Nikolay Samokhvalov.

## Credits

**postgres_dba** is based on useful queries created and improved by many developers. Here is incomplete list of them:
 * Jehan-Guillaume (ioguix) de Rorthais https://github.com/ioguix/pgsql-bloat-estimation
 * Alexey Lesovsky, Alexey Ermakov, Maxim Boguk, Ilya Kosmodemiansky et al. https://github.com/dataegret/pg-utils
 * Josh Berkus, Quinn Weaver et al. from PostgreSQL Experts, Inc. https://github.com/pgexperts/pgx_scripts

## Requirements

**You need psql version 10 or newer and a PostgreSQL 14-18 server.** The
client and server major versions do not need to match. PostgreSQL 18 psql is
recommended for the best client compatibility.

### Installing on Ubuntu

On clean Ubuntu, this is how you can get postgresql-client and have the most recent psql:
```bash
sudo sh -c "echo \"deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main\" >> /etc/apt/sources.list.d/pgdg.list"
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get update
sudo apt-get install -y postgresql-client-18
```

### Installing on macOS

On macOS, use Homebrew to install PostgreSQL client and pspg:

```bash
# Install PostgreSQL client (includes psql)
brew install libpq

# Add libpq to PATH (required because it's keg-only)
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# For Intel Macs, use:
# echo 'export PATH="/usr/local/opt/libpq/bin:$PATH"' >> ~/.zshrc

# Verify installation
psql --version

# Install pspg (recommended pager)
brew install pspg
```

Alternatively, you can install the full PostgreSQL package which includes psql:
```bash
brew install postgresql@18
```

### pspg - Enhanced psql Pager (Optional)

Using alternative psql pager called "pspg" is highly recommended but optional: https://github.com/okbob/pspg.

After installing pspg, configure it in your `~/.psqlrc`:
```bash
\setenv PAGER pspg
\pset border 2
\pset linestyle unicode
```

## Supported PostgreSQL Versions

**postgres_dba** is tested and supports **PostgreSQL 14-18**.

- ✅ **PostgreSQL 14** - Fully supported  
- ✅ **PostgreSQL 15** - Fully supported
- ✅ **PostgreSQL 16** - Fully supported
- ✅ **PostgreSQL 17** - Fully supported (includes `pg_stat_checkpointer` compatibility)
- ✅ **PostgreSQL 18** - Fully supported

PostgreSQL 13 and older are outside the supported and tested range. Existing
compatibility branches for older releases are retained where harmless, but do
not constitute a support guarantee.

## Installation
The installation is trivial. Clone the repository and put "dba" alias to your `.psqlrc` file (works in bash, zsh, and csh):
```bash
git clone https://github.com/zechel/postgres_dba.git
cd postgres_dba
printf "%s %s %s %s\n" \\echo 'postgres_dba installed. Use ":dba" to see menu' >> ~/.psqlrc
printf "%s %s %s %s\n" \\set dba \'\\\\i $(pwd)/start.psql\' >> ~/.psqlrc
```

That's it.

## Usage

### Connect to Local Postgres Server
If you are running psql and Postgres server on the same machine, just launch psql:
```bash
psql -U <username> <dbname>
```

And type `:dba <Enter>` in psql. (Or `\i /path/to/postgres_dba/start.psql` if you haven't added shortcut to your `~/.psqlrc` file).

– it will open interactive menu.

### Connect to Remote Postgres Server
What to do if you need to connect to a remote Postgres server? Usually, Postgres is behind a firewall and/or doesn't listen to a public network interface. So you need to be able to connect to the server using SSH. If you can do it, then just create SSH tunnel (assuming that Postgres listens to default port 5432 on that server:

```bash
ssh -fNTML 9432:localhost:5432 sshusername@your-server.com
```

Then, just launch psql, connecting to port 9432 at localhost:
```bash
psql -h localhost -p 9432 -U <username> <dbname>
```

And type `:dba <Enter>` in psql to launch **postgres_dba**.

### Connect to Heroku Postgres
Just open psql as you usually do with Heroku:
```bash
heroku pg:psql -a <your_project_name>
```

And then:
```
:dba
```

## Key Features

### Report ID migration

- **p1** now shows progress for `CREATE INDEX` and `REINDEX` operations.
- The former **p1** alignment-padding report moved to **x1**. Update any local
  automation that invokes `sql/p1_alignment_padding.sql` to use
  `sql/x1_alignment_padding.sql`.

### Rapid Incident Diagnostics

The interactive menu includes read-only checks designed for fast triage on
customer environments:

- **a3** – Connection capacity, utilization, remaining and reserved slots
- **a4** – Blocked sessions, long transactions, long queries and
  idle-in-transaction sessions
- **i7** – Largest tables without primary keys
- **r1** – Replication status, automatically adapted to primary or replica
- **r2** – Replication slots, retained WAL and transaction horizons
- **v3** – XID and MXID wraparound risk by database and table

The **s1** and **s2** `pg_stat_statements` reports use one implementation for
all supported server versions. They automatically map renamed timing columns
and include both shared and local I/O timing on PostgreSQL 17 and newer.

### Configuration inventory

- **t1** lists PostgreSQL server parameters.
- **t2** lists storage parameters explicitly configured on user tables,
  indexes, materialized views and partitioned relations. It reports configured
  values for auditing and troubleshooting; it does not make tuning
  recommendations.

### Extensions and execution cost

- **s1** and **s2** require `pg_stat_statements` in
  `shared_preload_libraries` and the extension installed in the current
  database. If the extension is absent, the reports explain the requirement
  instead of running the query.
- **b3** and **b4** require `pgstattuple`. They can scan large relations and
  are intentionally excluded from the automated smoke test; run them during
  an appropriate maintenance or diagnostic window.
- **b6** also requires `pgstattuple`, but uses `pgstattuple_approx()`, which
  consults the visibility map and skips all-visible pages. On vacuumed tables
  it reports the same numbers as **b3** at a small fraction of the cost, so it
  is the recommended starting point for measuring real bloat: **b1** and **b2**
  are free estimates, **b6** measures cheaply, and **b3** and **b4** measure
  exhaustively. It prompts for a minimum table size (100 MB by default) to keep
  the long tail of small relations out of the scan. A table that has never been
  vacuumed has an empty visibility map, so nothing can be skipped and the cost
  approaches a full scan.
- **i6** works both with and without the optional `intarray` extension.
- The automated matrix runs reports as superuser and as a role with
  `pg_monitor`. Some server objects can still require ownership or additional
  privileges.

### Interactive and automated reports

The menu is interactive by design. When reports are invoked directly in
automation, pass `--no-psqlrc -v ON_ERROR_STOP=1` and
`-v postgres_dba_interactive_mode=false`.

- **a2** prompts for a duration in the menu and uses zero seconds in explicit
  non-interactive mode.
- **b6** prompts for a minimum table size and uses 100 MB in explicit
  non-interactive mode, or when the prompt is answered with an empty line.
- **k1** and **k2** prompt for a backend PID and can cancel or terminate work.
- **u1** and **u2** prompt for role attributes and change server state.
- **k1**, **k2**, **u1** and **u2** are never executed by the automated test
  job. **b3** and **b4** are also excluded because of their cost.

### Secure Role Management

**postgres_dba** includes interactive tools for secure role (user) management:

- **u1** – Create user with random password (interactive)
- **u2** – Alter user with random password (interactive)

These tools help prevent password exposure in psql history, logs, and command-line process lists by:
- Generating secure random 16-character passwords
- Using interactive prompts instead of command-line arguments
- Only displaying the password once at creation/alteration time

**Usage example:**
```sql
-- In psql, after launching :dba
-- Select option u1 to create a new user
-- The script will prompt you for:
--   - Username
--   - Superuser privilege (yes/no)
--   - Login privilege (yes/no)
-- The generated password will be displayed once in the output

-- To see the password, set client_min_messages to DEBUG first:
set client_min_messages to DEBUG;
```

**Security note:** These are DBA tools designed for trusted environments where the user already has superuser privileges. The password is shown in the psql output, so ensure you're working in a secure session.

## How to Extend (Add More Queries)
You can add your own useful SQL queries and use them from the main menu. Just add your SQL code to `./sql` directory. The filename should start with some 1 or 2-letter code, followed by underscore and some additional arbitrary words. Extension should be `.sql`. Example:
```
  sql/f1_cool_query.sql
```
– this will give you an option "f1" in the main menu. The very first line in the file should be an SQL comment (starts with `--`) with the query description. It will automatically appear in the menu.

Once you added your queries, regenerate `start.psql` file:
```bash
/bin/bash ./init/generate.sh
```

Repository contributors must also classify every new report in the explicit
automation or exclusion list in `.github/workflows/test.yml`; an unclassified
report fails CI.

Now you have the new `start.psql` and can use it as described above.

‼️ If your new queries are good consider sharing them with public. The best way to do it is to open a Pull Request (https://help.github.com/articles/creating-a-pull-request/).

## Uninstallation
No steps are needed, just delete **postgres_dba** directory and remove `\set dba ...` in your `~/.psqlrc` if you added it.
