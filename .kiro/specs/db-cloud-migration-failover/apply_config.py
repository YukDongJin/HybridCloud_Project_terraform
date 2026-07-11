import pymysql

try:
    conn = pymysql.connect(
        host='127.0.0.1', 
        port=6032, 
        user='admin', 
        password='admin', 
        autocommit=True
    )
    cur = conn.cursor()

    # 관리자 계정 정보 업데이트 및 런타임 반영
    cur.execute("UPDATE global_variables SET variable_value='admin:admin;radmin:radmin' WHERE variable_name='admin-admin_credentials';")
    cur.execute("LOAD ADMIN VARIABLES TO RUNTIME;")
    cur.execute("SAVE ADMIN VARIABLES TO DISK;")
    
    # 반영 결과 출력
    cur.execute("SELECT * FROM global_variables WHERE variable_name='admin-admin_credentials';")
    print(f"현재 관리자 설정: {cur.fetchone()}")
    
    conn.close()
    print("ProxySQL 설정이 성공적으로 업데이트되었습니다.")
except Exception as e:
    print(f"접속 실패: {e}")