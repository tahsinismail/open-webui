#!/bin/bash

# Enhanced SQLite to PostgreSQL Migration Script for Open WebUI
# This script leverages Open WebUI's built-in dual migration system (Peewee + Alembic)

set -e

echo "🚀 Open WebUI: Enhanced SQLite to PostgreSQL Migration"
echo "====================================================="

# Function to check if container is running
check_container() {
    local container_name=$1
    if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# Function to wait for database to be ready
wait_for_postgres() {
    echo "⏳ Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker compose exec postgres pg_isready -U openwebui -d openwebui &> /dev/null; then
            echo "✅ PostgreSQL is ready!"
            return 0
        fi
        
        echo "   Attempt $attempt/$max_attempts - PostgreSQL not ready yet..."
        sleep 2
        ((attempt++))
    done
    
    echo "❌ PostgreSQL failed to start within timeout"
    return 1
}

# Function to backup SQLite data
backup_sqlite_data() {
    echo "📋 Creating comprehensive SQLite backup..."
    local backup_dir="sqlite_backup_$(date +%Y%m%d_%H%M%S)"
    
    # Create backup directory on host
    mkdir -p "$backup_dir"
    
    # Export SQLite data
    docker run --rm \
        -v open-webui:/app/backend/data \
        -v "$(pwd)/$backup_dir:/backup" \
        alpine sh -c "
            if [ -f /app/backend/data/webui.db ]; then
                echo 'Copying SQLite database...'
                cp /app/backend/data/webui.db /backup/
                echo 'Creating SQLite dump...'
                apk add --no-cache sqlite
                sqlite3 /app/backend/data/webui.db '.dump' > /backup/webui_dump.sql
                echo 'Listing all tables...'
                sqlite3 /app/backend/data/webui.db '.tables' > /backup/tables_list.txt
                echo 'Getting table schemas...'
                sqlite3 /app/backend/data/webui.db '.schema' > /backup/schema.sql
                echo 'SQLite backup completed in /backup/'
                ls -la /backup/
            else
                echo 'No SQLite database found - fresh installation'
                touch /backup/no_sqlite_db
            fi
        "
    
    echo "✅ SQLite backup created in: $backup_dir"
    echo "$backup_dir"
}

# Function to check SQLite data
check_sqlite_data() {
    if docker run --rm -v open-webui:/data alpine sh -c 'test -f /data/webui.db'; then
        echo "📊 Analyzing existing SQLite database..."
        
        # Get table count and basic stats
        docker run --rm \
            -v open-webui:/app/backend/data \
            alpine sh -c "
                apk add --no-cache sqlite > /dev/null 2>&1
                echo 'SQLite Database Analysis:'
                echo '========================'
                if [ -f /app/backend/data/webui.db ]; then
                    echo 'Tables:'
                    sqlite3 /app/backend/data/webui.db '.tables'
                    echo ''
                    echo 'Row counts:'
                    for table in \$(sqlite3 /app/backend/data/webui.db '.tables'); do
                        count=\$(sqlite3 /app/backend/data/webui.db \"SELECT COUNT(*) FROM \$table;\")
                        echo \"  \$table: \$count rows\"
                    done
                else
                    echo 'No SQLite database found'
                fi
            "
        return 0
    else
        echo "ℹ️  No SQLite database found - fresh installation"
        return 1
    fi
}

# Step 1: Check existing SQLite data
echo "📋 Step 1: Checking for existing SQLite database..."
HAS_SQLITE=false
if check_sqlite_data; then
    HAS_SQLITE=true
    
    # Create backup before proceeding
    BACKUP_DIR=$(backup_sqlite_data)
fi

# Step 2: Start PostgreSQL
echo "📋 Step 2: Starting PostgreSQL..."
docker compose up -d postgres

if ! wait_for_postgres; then
    echo "❌ Failed to start PostgreSQL"
    exit 1
fi

# Step 3: Initialize PostgreSQL with Open WebUI's migration system
echo "📋 Step 3: Running Open WebUI migration system..."

if [ "$HAS_SQLITE" = true ]; then
    echo "   🔄 Starting migration from SQLite to PostgreSQL..."
    echo "   This process leverages Open WebUI's built-in dual migration system:"
    echo "   - Peewee migrations handle legacy schema"
    echo "   - Alembic migrations handle current schema"
    echo "   - Automatic data transfer between databases"
else
    echo "   🆕 Fresh PostgreSQL installation - no data to migrate"
fi

# Start Open WebUI with PostgreSQL - it will handle migrations automatically
echo "   Starting Open WebUI with PostgreSQL..."
docker compose up -d open-webui

# Wait for migration to complete
echo "   ⏳ Waiting for Open WebUI to complete initialization and migrations..."
sleep 20

# Check if Open WebUI started successfully
max_attempts=60
attempt=1
while [ $attempt -le $max_attempts ]; do
    if docker compose logs open-webui 2>&1 | grep -q -E "(Application startup complete|Uvicorn running)" && \
       ! docker compose logs open-webui 2>&1 | grep -q -E "(ERROR|CRITICAL|Failed)"; then
        echo "✅ Open WebUI started successfully!"
        break
    elif docker compose logs open-webui 2>&1 | grep -q -E "(ERROR|CRITICAL|Failed)"; then
        echo "❌ Open WebUI startup failed. Check logs:"
        docker compose logs open-webui | tail -20
        exit 1
    fi
    
    echo "   Attempt $attempt/$max_attempts - Open WebUI still initializing..."
    sleep 5
    ((attempt++))
done

if [ $attempt -gt $max_attempts ]; then
    echo "❌ Open WebUI failed to start within timeout. Check logs:"
    docker compose logs open-webui | tail -20
    exit 1
fi

# Step 4: Verify migration success
echo "📋 Step 4: Verifying migration success..."

# Check PostgreSQL tables
echo "   Checking PostgreSQL schema..."
docker compose exec postgres psql -U openwebui -d openwebui -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;" 2>/dev/null | grep -v "table_name\|---\|(" | grep -v "^$" > /tmp/pg_tables.txt || true

if [ -s /tmp/pg_tables.txt ]; then
    echo "✅ PostgreSQL tables created:"
    cat /tmp/pg_tables.txt | sed 's/^/   - /'
    
    # Get row counts if we had SQLite data
    if [ "$HAS_SQLITE" = true ]; then
        echo ""
        echo "   Row counts in PostgreSQL:"
        while read -r table; do
            table=$(echo "$table" | xargs)  # trim whitespace
            if [ -n "$table" ]; then
                count=$(docker compose exec postgres psql -U openwebui -d openwebui -t -c "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null | xargs || echo "0")
                echo "   - $table: $count rows"
            fi
        done < /tmp/pg_tables.txt
    fi
else
    echo "⚠️  No tables found in PostgreSQL - this might indicate an issue"
fi

# Step 5: Final startup
echo "📋 Step 5: Final service startup..."
docker compose up -d

# Wait for all services
echo "⏳ Waiting for all services to be healthy..."
sleep 10

# Check if all services are running
if check_container "open-webui" && check_container "open-webui-postgres" && check_container "tika"; then
    echo ""
    echo "🎉 Migration completed successfully!"
    echo "=================================="
    echo "✅ PostgreSQL is running (port 5433 externally)"
    echo "✅ Open WebUI is running on port 3004"
    echo "✅ Tika is running on port 9998"
    echo ""
    echo "📊 Database Information:"
    echo "   • Database: openwebui"
    echo "   • User: openwebui"
    echo "   • External Port: localhost:5433"
    echo "   • Internal Port: postgres:5432"
    echo ""
    
    if [ "$HAS_SQLITE" = true ]; then
        echo "💾 SQLite Migration Information:"
        echo "   • Original SQLite database: backed up in $BACKUP_DIR"
        echo "   • Migration: Completed using Open WebUI's built-in system"
        echo "   • Data transferred: Check PostgreSQL row counts above"
        echo ""
        echo "🧹 Cleanup (optional):"
        echo "   After verifying everything works correctly, you can:"
        echo "   1. Remove SQLite backup: rm -rf $BACKUP_DIR"
        echo "   2. Remove SQLite from volume: docker run --rm -v open-webui:/data alpine rm -f /data/webui.db*"
        echo ""
    fi
    
    echo "🌐 Access Open WebUI at: http://localhost:3004"
    echo ""
    echo "🔍 Useful commands:"
    echo "   • View logs: docker compose logs -f"
    echo "   • PostgreSQL CLI: docker compose exec postgres psql -U openwebui -d openwebui"
    echo "   • Check status: docker compose ps"
    
else
    echo "❌ Some services failed to start properly"
    echo "Check logs with: docker compose logs"
    echo ""
    echo "Container status:"
    docker compose ps
    exit 1
fi

# Cleanup temp files
rm -f /tmp/pg_tables.txt

echo ""
echo "Migration process completed! 🚀"
