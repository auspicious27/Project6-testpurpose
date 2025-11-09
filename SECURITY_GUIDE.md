# 🔒 Security Guide - AWS Credentials

## Important: Never Commit AWS Credentials!

### ✅ What's Protected

The following files are in `.gitignore` and will **NOT** be committed to git:

- `aws_credentials.env` - Your actual AWS credentials
- `*.pem` - SSH key files
- `*.key` - Key files
- `*.log` - Log files
- `.env` - Environment files

### 📋 How to Use AWS Credentials

#### Method 1: Using aws_credentials.env (Recommended)

1. **Copy the example file:**
   ```bash
   cp aws_credentials.example.env aws_credentials.env
   ```

2. **Edit aws_credentials.env with your credentials:**
   ```bash
   nano aws_credentials.env
   # or
   vi aws_credentials.env
   ```

3. **Fill in your credentials:**
   ```
   AWS_ACCESS_KEY_ID=your-access-key-id
   AWS_SECRET_ACCESS_KEY=your-secret-access-key
   AWS_REGION=us-east-1
   ```

4. **Run scripts:**
   ```bash
   ./complete_aws_setup.sh
   ```

#### Method 2: Using Environment Variables

```bash
export AWS_ACCESS_KEY_ID=your-access-key-id
export AWS_SECRET_ACCESS_KEY=your-secret-access-key
export AWS_REGION=us-east-1

./complete_aws_setup.sh
```

#### Method 3: Using AWS CLI Configuration

```bash
aws configure
# Enter your credentials when prompted
```

### 🚨 Security Best Practices

1. **Never commit credentials:**
   - ✅ `aws_credentials.env` is in `.gitignore`
   - ✅ Never add credentials to any script files
   - ✅ Never commit `.pem` or `.key` files

2. **Rotate credentials regularly:**
   - Change AWS access keys every 90 days
   - Use IAM roles when possible

3. **Use least privilege:**
   - Create IAM user with only necessary permissions
   - Don't use root account credentials

4. **Secure local files:**
   ```bash
   # Set proper permissions
   chmod 600 aws_credentials.env
   chmod 400 *.pem
   ```

### 📝 Files Structure

```
project6/
├── .gitignore                    # Protects sensitive files
├── aws_credentials.example.env   # Template (safe to commit)
├── aws_credentials.env          # Your credentials (NOT in git)
└── complete_aws_setup.sh        # Script (reads from env)
```

### ✅ Verification

Check if credentials are protected:

```bash
# Check .gitignore
cat .gitignore | grep aws_credentials

# Verify file is ignored
git status aws_credentials.env
# Should show: nothing to commit (file is ignored)
```

### 🔄 If You Accidentally Committed Credentials

1. **Remove from git history:**
   ```bash
   git rm --cached aws_credentials.env
   git commit -m "Remove credentials from git"
   ```

2. **Rotate AWS credentials immediately:**
   - Go to AWS Console → IAM → Users
   - Delete old access keys
   - Create new access keys

3. **Update local file:**
   ```bash
   # Update aws_credentials.env with new credentials
   ```

### 📚 Additional Resources

- [AWS Security Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Git Secrets Management](https://git-scm.com/book/en/v2/Git-Tools-Credential-Storage)

---

**Remember**: Always check `.gitignore` before committing sensitive files!

