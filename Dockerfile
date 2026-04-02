FROM python:3.11-slim

WORKDIR /app

# 安装依赖（独立层，加速重复构建）
COPY requirements.txt .
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt

# 复制项目文件
COPY . .

# 时区设为上海（保证 is_trading() 判断正确）
ENV TZ=Asia/Shanghai
# 禁用 Python 输出缓冲，确保 docker logs 能实时看到输出
ENV PYTHONUNBUFFERED=1

# 默认启动 web，collector 服务在 docker-compose 中覆盖 CMD
CMD ["python", "app.py"]
