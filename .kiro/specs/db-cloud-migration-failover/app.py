from flask import Flask, render_template_string, request, redirect, url_for
import pymysql
from pymysql import cursors
from dbutils.pooled_db import PooledDB
import socket
from datetime import datetime

app = Flask(__name__)

# 로컬 테스트: MySQL 직접 연결 (ProxySQL 없이)
# AWS 배포 후: <MYSQL_IP>를 ProxySQL IP로 변경하고 port를 6033으로 변경
pool = PooledDB(
    creator=pymysql,
    maxconnections=5,
    host="192.168.219.116",  # 로컬: MySQL VM IP, AWS: ProxySQL/NLB IP
    port=3306,           # 로컬: 3306, AWS: 6033 (ProxySQL)
    user="was_user",
    password="test1234",
    database="toydb",
    cursorclass=cursors.DictCursor
)

@app.route('/')
def index():
    try:
        conn = pool.connection()
        cursor = conn.cursor()
        
        # DB 연결 정보
        cursor.execute("SELECT @@hostname AS db_host, NOW() as now")
        db_info = cursor.fetchone()
        
        # 회원 목록 조회
        cursor.execute("SELECT * FROM users ORDER BY created_at DESC")
        users = cursor.fetchall()
        
        cursor.close()
        conn.close()

        return render_template_string('''
            <!DOCTYPE html>
            <html>
            <head>
                <title>DB Migration Failover Test</title>
                <style>
                    body { font-family: Arial, sans-serif; margin: 40px; }
                    .info { background: #e3f2fd; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
                    table { border-collapse: collapse; width: 100%; margin-top: 20px; }
                    th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
                    th { background-color: #4CAF50; color: white; }
                    tr:hover { background-color: #f5f5f5; }
                    .form-group { margin-bottom: 15px; }
                    input[type="text"], input[type="email"] { width: 300px; padding: 8px; }
                    button { background-color: #4CAF50; color: white; padding: 10px 20px; border: none; cursor: pointer; }
                    button:hover { background-color: #45a049; }
                    .delete-btn { background-color: #f44336; }
                    .delete-btn:hover { background-color: #da190b; }
                </style>
            </head>
            <body>
                <h1>🔄 DB Migration Failover Test</h1>
                
                <div class="info">
                    <p><strong>WAS Host:</strong> {{ was_host }}</p>
                    <p><strong>Connected DB Host:</strong> {{ db_host }}</p>
                    <p><strong>Current Time:</strong> {{ now }}</p>
                </div>

                <h2>📝 회원 가입</h2>
                <form action="/register" method="post">
                    <div class="form-group">
                        <input type="text" name="name" placeholder="이름" required>
                    </div>
                    <div class="form-group">
                        <input type="email" name="email" placeholder="이메일" required>
                    </div>
                    <button type="submit">가입하기</button>
                </form>

                <h2>👥 회원 목록 ({{ user_count }}명)</h2>
                <table>
                    <tr>
                        <th>ID</th>
                        <th>이름</th>
                        <th>이메일</th>
                        <th>가입일시</th>
                        <th>수정일시</th>
                        <th>작업</th>
                    </tr>
                    {% for user in users %}
                    <tr>
                        <td>{{ user.id }}</td>
                        <td>{{ user.name }}</td>
                        <td>{{ user.email }}</td>
                        <td>{{ user.created_at }}</td>
                        <td>{{ user.updated_at or '-' }}</td>
                        <td>
                            <form action="/update/{{ user.id }}" method="post" style="display:inline;">
                                <input type="text" name="name" placeholder="새 이름" required>
                                <button type="submit">수정</button>
                            </form>
                            <form action="/delete/{{ user.id }}" method="post" style="display:inline;">
                                <button type="submit" class="delete-btn" onclick="return confirm('정말 삭제하시겠습니까?')">삭제</button>
                            </form>
                        </td>
                    </tr>
                    {% endfor %}
                </table>
            </body>
            </html>
        ''', was_host=socket.gethostname(), 
             db_host=db_info['db_host'], 
             now=db_info['now'],
             users=users,
             user_count=len(users))
    except Exception as e:
        return f"<h1>Error</h1><p>{str(e)}</p>"

@app.route('/register', methods=['POST'])
def register():
    try:
        name = request.form['name']
        email = request.form['email']
        
        conn = pool.connection()
        cursor = conn.cursor()
        
        cursor.execute(
            "INSERT INTO users (name, email, created_at) VALUES (%s, %s, NOW())",
            (name, email)
        )
        conn.commit()
        
        cursor.close()
        conn.close()
        
        return redirect(url_for('index'))
    except Exception as e:
        return f"<h1>Error</h1><p>{str(e)}</p>"

@app.route('/update/<int:user_id>', methods=['POST'])
def update(user_id):
    try:
        name = request.form['name']
        
        conn = pool.connection()
        cursor = conn.cursor()
        
        cursor.execute(
            "UPDATE users SET name = %s, updated_at = NOW() WHERE id = %s",
            (name, user_id)
        )
        conn.commit()
        
        cursor.close()
        conn.close()
        
        return redirect(url_for('index'))
    except Exception as e:
        return f"<h1>Error</h1><p>{str(e)}</p>"

@app.route('/delete/<int:user_id>', methods=['POST'])
def delete(user_id):
    try:
        conn = pool.connection()
        cursor = conn.cursor()
        
        cursor.execute("DELETE FROM users WHERE id = %s", (user_id,))
        conn.commit()
        
        cursor.close()
        conn.close()
        
        return redirect(url_for('index'))
    except Exception as e:
        return f"<h1>Error</h1><p>{str(e)}</p>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
